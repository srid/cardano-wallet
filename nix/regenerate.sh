#!/usr/bin/env bash

set -euo pipefail

cd $(dirname "$0")/..

# Regenerate sha256map.nix
nix-build ./nix -A sha256mapRegenerate
./result

# Regenerate stack-to-nix files in ./.stack-nix
rm -f nix/materialized/stack-nix/.stack-to-nix.cache #https://github.com/input-output-hk/haskell.nix/issues/57
nix-build ./nix -A cardanoWalletHaskellProject.stack-nix.passthru.generateMaterialized
./result nix/materialized/stack-nix/

# Regenerate materialized haskell-build-tools in ./materialized
nix-build ./nix -A haskell-build-tools.regenerateMaterialized
./result/bin/regenerate-materialized-nix

# Regenerate materialized iohk-nix-utils in ./materialized
nix-build ./nix -A iohk-nix-utils.regenerateMaterialized
./result/bin/regenerate-materialized-nix

# Regenerate the list of the project packages:
nix eval -f nix/default.nix cardanoWalletLib.projectPackageList > nix/project-package-list.nix.new
mv nix/project-package-list.nix.new nix/project-package-list.nix
