{ evalService
, project
, customConfigs
}:
with project.pkgs;
let
  mkScript = envConfig:
    let
      service = evalService {
        inherit pkgs customConfigs;
        serviceName = "cardano-wallet";
        modules = [
          ./nixos/cardano-wallet-service.nix
          ({ config, ... }: {
            services.cardano-wallet = let cfg = config.services.cardano-wallet; in
              {
                project = lib.mkDefault project;
                environment = lib.mkDefault envConfig.name;
                database = lib.mkDefault "./db-cardano-wallet-${cfg.environment}";
              };
          })
        ];
      };

    in
    writeScriptBin "cardano-wallet-${service.environment}" ''
      #!${pkgs.runtimeShell}
      set -euo pipefail
      ${service.script} $@
    '';

  debugDeps = with pkgs; [
    coreutils
    findutils
    gnugrep
    gnused
    postgresql
    strace
    lsof
    dnsutils
    bashInteractive
    iproute
    curl
    netcat
    bat
    tree
  ];

in
cardanoLib.forEnvironments (environment: lib.recurseIntoAttrs rec {
  wallet = mkScript environment;
  wallet-debug = pkgs.symlinkJoin {
    inherit (wallet) name;
    paths = [ wallet ] ++ debugDeps;
  };
})
