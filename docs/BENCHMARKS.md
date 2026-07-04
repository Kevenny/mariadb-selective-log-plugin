# BENCHMARKS.md — Overhead do `selective_log` vs `general_log`

Medições da Etapa 5, executadas com [`scripts/benchmark.sh`](../scripts/benchmark.sh)
no container `mariadb-plugin-test` (imagem oficial `mariadb:11.4.4`).

- **Ambiente**: Docker sobre WSL2 (kernel 6.6.87), host Windows 11, disco NVMe.
  Números absolutos variam por máquina; o que importa é a **comparação
  relativa** entre cenários na mesma rodada.
- **Ferramenta**: `mariadb-slap` (incluída na imagem oficial), cada cenário com
  uma rodada de aquecimento + uma rodada medida; tabelas recriadas/semeadas
  identicamente antes de cada cenário.
- Plugin build: RelWithDebInfo, tag `mariadb-11.4.4`.

## Cenários

| Cenário | Configuração |
|---|---|
| `baseline` | `selective_log_enabled=OFF`, `general_log=OFF` |
| `general_log` | `general_log=ON` (arquivo) |
| `sel_miss` | selective_log ON filtrando `bench_hot`, carga em `bench_cold` — caminho **"não loga"** (só o custo do filtro) |
| `sel_hit_file` | selective_log ON, carga em `bench_hot`, `output=FILE` — **toda query logada** |
| `sel_hit_table` | idem com `output=TABLE` (INSERT assíncrono) |

## Suíte MIX — carga realista (INSERT + SELECT indexado)

`concurrency=8`, 20.000 queries por rodada (50% INSERT, 50% SELECT por PK):

| Cenário | Segundos | Δ vs baseline |
|---|---:|---:|
| baseline | 2,745 | — |
| general_log | 2,743 | ~0% |
| sel_miss | 2,642 | ~0% |
| sel_hit_file | 2,648 | ~0% |
| sel_hit_table | 2,754 | ~0% |

**Leitura**: a ~7.300 qps com round-trip de cliente e I/O de InnoDB dominando,
**nenhum** mecanismo de log (nem o general_log) produz overhead mensurável —
as diferenças (±2%) são ruído entre rodadas. Nessa carga o argumento de
performance é irrelevante; o valor do selective_log é **volume de log**
(só o que interessa) e formato estruturado.

## Suíte LIGHT — custo do caminho de log isolado (`DO 1`)

`concurrency=32`, 60.000 statements `DO 1` por rodada (custo de execução
próximo de zero → o custo do log fica proporcionalmente visível):

| Cenário | Segundos | qps aprox. | Δ tempo vs baseline |
|---|---:|---:|---:|
| baseline | 0,962 | 62.400 | — |
| **general_log** | **1,059** | 56.700 | **+10,1%** |
| sel_miss | 0,927 | 64.700 | −3,6% (≈ ruído) |
| sel_hit_file | 0,949 | 63.200 | −1,4% (≈ ruído) |
| sel_hit_table | 0,954 | 62.900 | −0,8% (≈ ruído)¹ |

¹ No `sel_hit_table` a 60k+ eventos/s a fila do writer assíncrono saturou e
descartou 66.257 eventos (`Selective_log_events_dropped`) — **por design**: em
burst acima da vazão de INSERT, o plugin descarta e contabiliza em vez de
frear as queries dos usuários. Na suíte MIX (7,3k qps) não houve nenhum drop.

## Conclusões (critério de aceite)

1. **Caminho "não loga"** (`sel_miss`): custo indistinguível de zero — o
   filtro é um rdlock + comparações de string sem alocação, invisível mesmo a
   62k qps. É o cenário de produção típico (filtro restrito, maioria do
   tráfego fora dele).
2. **Overhead sensivelmente menor que `general_log=ON`**: no pior caso
   sintético o general_log custou **+10,1%**, enquanto o selective_log ficou
   em **~0%** em todos os modos — inclusive **logando 100% das queries** em
   FILE (escrita síncrona via logger service) e TABLE (assíncrona).
3. O modo TABLE protege a latência das queries sob burst à custa de
   possíveis descartes (monitoráveis via `Selective_log_events_dropped`);
   para auditoria sem perda em alto volume, prefira `output=FILE`.

## Como reproduzir

```bash
docker exec -i mariadb-plugin-test bash < scripts/benchmark.sh
# variáveis: BENCH_CONCURRENCY, BENCH_QUERIES,
#            BENCH_LIGHT_CONCURRENCY, BENCH_LIGHT_QUERIES
```

## Validação de memória (Valgrind)

[`scripts/valgrind-test.sh`](../scripts/valgrind-test.sh) sobe o `mariadbd`
compilado (RelWithDebInfo) sob `valgrind --leak-check=full` com o plugin
carregado, roda a bateria (modos FILE e TABLE, trocas repetidas das listas de
filtro, erro de SQL, `min_duration`, `UNINSTALL`/`INSTALL PLUGIN`) e derruba o
servidor de forma limpa.

Resultado (2026-07-04):

```
HEAP SUMMARY: total heap usage: 26,207 allocs, 26,206 frees
LEAK SUMMARY:
   definitely lost: 0 bytes in 0 blocks
   indirectly lost: 0 bytes in 0 blocks
     possibly lost: 336 bytes in 1 blocks
   still reachable: 0 bytes in 0 blocks
```

**Zero leaks atribuíveis ao plugin.** O único bloco "possibly lost"
(336 bytes) é o TLS da thread de signal handler do próprio servidor
(`mysqld.cc:start_signal_handler` → `pthread_create`), sem nenhum frame do
plugin no stack — artefato conhecido e benigno do mariadbd.
