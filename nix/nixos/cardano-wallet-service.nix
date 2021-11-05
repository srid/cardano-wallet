{ config, lib, pkgs, ... }:
let
  cfg = config.services.cardano-wallet;
  inherit (lib) optionalString mkIf mkEnableOption mkOption types;
  logLevels = types.enum [ "debug" "info" "notice" "warning" "error" "critical" "alert" "emergency" "off" ];
  cardanoEnvAttrs = cfg.environments.${cfg.environment};
in
{
  options.services.cardano-wallet = {

    enable = mkEnableOption "Cardano Wallet service";

    script = mkOption {
      type = types.str;
      internal = true;
      default =
        let
          genesisFile = cardanoEnvAttrs.genesisFile
            or cardanoEnvAttrs.nodeConfig.ByronGenesisFile;
        in
        toString ([
          "exec ${cfg.package}/bin/cardano-wallet serve"
          "--listen-address \"${cfg.listenAddress}\""
          "--port ${toString cfg.port}"
          "--node-socket \"$CARDANO_NODE_SOCKET_PATH\""
          "--sync-tolerance ${toString cfg.syncTolerance}s"
          "--pool-metadata-fetching ${if (cfg.poolMetadataFetching == "smash")
              then cardanoEnvAttrs.smashUrl
              else cfg.poolMetadataFetching}"
          "--log-level ${cfg.logLevel}"
          "--${cfg.walletMode}"
        ] ++ lib.optional (cfg.walletMode != "mainnet")
          "\"${genesisFile}\""
        ++ lib.optional (cfg.tokenMetadataServer != null)
          "--token-metadata-server ${cfg.tokenMetadataServer}"
        ++ lib.optional (cfg.database != null)
          "--database \"${cfg.database}\""
        ++ lib.mapAttrsToList
          (name: level: ''
            --trace-${name}=${level} '')
          cfg.trace
        ++ cfg.rtsArgs)
      ;
    };

    project = mkOption {
      type = types.attrs;
      default = (import ../.. { }).legacyPackages.${pkgs.system};
      description = "The cardano-wallet haskell.nix project attribute set.";
    };

    package = mkOption {
      type = types.package;
      default = cfg.project.hsPkgs.cardano-wallet.components.exes.cardano-wallet;
      description = "Package for the cardano wallet executable.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "*";
      description = "Which host to bind the API server to.";
    };

    port = mkOption {
      type = types.port;
      default = 8090;
      description = "The default port cardano wallet will listen on.";
    };

    nodeSocket = mkOption {
      type = types.str;
      default = "/run/cardano-node/node.socket";
      description = ''Cardano-Node local communication socket path.'';
    };

    environment = mkOption {
      type = types.enum (builtins.attrNames cfg.environments);
      default = "testnet";
      description = ''
        The environment name to configure the wallet for.
        This name can be an environment name from those found at
        iohk-nix/cardano-lib/default.nix, or, it can be a custom
        name, for example, if launching a test cluster that does
        not have an environment yet defined in iohk-nix.  If custom,
        the environments option must contain an entry for this environment,
        of the same form as in cardano-lib environments found
        in iohk-nix.
      '';
    };

    environments = mkOption {
      type = types.attrsOf types.attrs;
      default = cfg.project.pkgs.cardanoLib.environments;
      description = ''
        The set of possible environment attribute set to configure the wallet for.
        Default to the set of environments found at
        iohk-nix/cardano-lib/default.nix, or, it must be an attribute set
        of the same form.
      '';
    };

    walletMode = mkOption {
      type = types.enum [ "mainnet" "staging" "testnet" ];
      default =
        if cfg.environment == "mainnet"
        then "mainnet"
        else if cfg.environment == "staging"
        then "staging"
        else "testnet";
      description = "Which mode to start wallet in: --mainnet, --staging or --testnet";
    };

    database = mkOption {
      type = types.nullOr types.str;
      default = "$STATE_DIRECTORY";
      description = ''Directory for storing wallets. Run in-memory if null.'';
    };

    syncTolerance = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Time duration within which we consider being synced with the network. Expressed in seconds.";
    };

    poolMetadataFetching = mkOption {
      type = types.enum [ "none" "direct" "smash" ];
      default = if cardanoEnvAttrs ? smashUrl then "smash" else "none";
      description = ''
        Sets the stake pool metadata fetching strategy.
        "smash" will use the 'smashUrl' attribute of the 'environnement'
        as metadata proxy server (default if exists).
        Use "direct" to fetch directly from the
        registered pool URLs, or "none" to completely disable
        stake pool metadata (default if no 'smashUrl' defined).'';
    };

    tokenMetadataServer = mkOption {
      type = types.nullOr types.str;
      default = cardanoEnvAttrs.metadataUrl or null;
      description = ''
        Sets the URL of the token metadata server,
        default to 'metadataUrl' of the 'environnement' attribute, if exists.
        If unset, metadata will not be fetched. By using this
        option, you are fully trusting the operator of the
        metadata server to provide authentic token metadata.
      '';
    };

    logLevel = mkOption {
      type = logLevels;
      default = "info";
      description = "Global minimum severity for a message to be logged.";
    };

    trace = mkOption {
      type = types.attrsOf logLevels;
      default = { };
      description = ''
        For each tracer, minimum severity for a message to be logged, or
        "off" to disable the tracer".
      '';
    };

    rtsArgs = mkOption {
      type = types.listOf types.str;
      default = [ "-N2" ];
      apply = args:
        if args != [ ] then
          [ "+RTS" ] ++ args ++ [ "-RTS" ]
        else [ ];
      description = ''Extra CLI args for 'cardano-wallet', to be surrounded by "+RTS"/"-RTS"'';
    };

  };

  config = mkIf cfg.enable {

    systemd.services.cardano-wallet = {
      description = "cardano-wallet daemon";
      wantedBy = [ "multi-user.target" ];
      inherit (cfg) script;

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "cardano-wallet/${cfg.environment}";
      };

      environment = {
        CARDANO_NODE_SOCKET_PATH = cfg.nodeSocket;
      };
    };
  };
}
