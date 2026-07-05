#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-mtr.sh — roda a suíte de integração MTR do plugin.
#
# O mysql-test-run resolve suites relativo ao *source tree* do MariaDB, então
# instalamos src/mysql-test/suite/selective_log lá antes de chamar o mtr. No
# empacotamento oficial (make install) isso é feito pelo INSTALL_MYSQL_TEST do
# MYSQL_ADD_PLUGIN; aqui replicamos para o fluxo de dev no build tree.
#
# Uso (dentro do container dev):  ./scripts/run-mtr.sh [args extra do mtr]
#   ou do host:  docker exec mariadb-plugin-dev bash -lc './scripts/run-mtr.sh'
# ---------------------------------------------------------------------------
set -euo pipefail

MARIADB_SRC_DIR="${MARIADB_SRC_DIR:-/opt/mariadb-src}"
BUILD_DIR="${BUILD_DIR:-/opt/mariadb-build}"
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUITE_SRC="${WORKSPACE_DIR}/src/mysql-test/suite/selective_log"
SUITE_DST="${MARIADB_SRC_DIR}/mysql-test/suite/selective_log"

echo ">> Instalando a suíte MTR em ${SUITE_DST}"
rm -rf "${SUITE_DST}"
cp -r "${SUITE_SRC}" "${SUITE_DST}"

echo ">> Garantindo o plugin compilado"
if [ ! -f "${BUILD_DIR}/plugin/selective_log/selective_log.so" ]; then
    (cd "${BUILD_DIR}" && ninja selective_log)
fi

echo ">> Rodando mtr --suite=selective_log"
cd "${BUILD_DIR}/mysql-test"
exec ./mtr --suite=selective_log "$@"
