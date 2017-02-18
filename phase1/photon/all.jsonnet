local cfg = import "../../.config.json";
{
  ["photon-%(cluster_name)s.tf" % cfg.phase1]: (import "photon.jsonnet")(cfg),
}
