function(config)
  local tf = import "phase1/tf.jsonnet";
  local cfg = config.phase1;
  local vms = std.makeArray(cfg.num_nodes + 1,function(node) node+1); 
  local master_dependency_list = ["photon_virtual_machine.kubevm%d" % vm for vm in vms];
  local node_name_to_ip = [("${photon_virtual_machine.kubevm%d.ip_address} %s"  % [vm, (if vm == 1 then "master" else "node%d" % (vm-1) )])  for vm in vms];
  local vm_username = "root";
  local vm_password = "kubernetes";

  local kubeconfig(user, cluster, context) =
    std.manifestJson(
      tf.pki.kubeconfig_from_certs(
        user, cluster, context,
        cfg.cluster_name + "-root",
        "https://${photon_virtual_machine.kubevm1.ip_address}",
      ));

  local config_metadata_template = std.toString(config {
      master_ip: "${photon_virtual_machine.kubevm1.ip_address}",
      role: "%s",
      phase3 +: {
        addons_config: (import "phase3/all.jsonnet")(config),
      },
    });
  
  std.mergePatch({
    // Photon Configuration
    provider: {
      photon: {
        photon_server: "https://"+cfg.photon.url+":4343",
        photon_ignoreCertificate: true,
        photon_tenant: cfg.photon.tenant,
        photon_project: cfg.photon.project,
        photon_overrideIP: true,
      },
    },
    
     data: {
      template_file: {
        configure_master: {
          template: "${file(\"configure-vm.sh\")}",
          vars: {
            role: "master",
            root_ca_public_pem: "${base64encode(tls_self_signed_cert.%s-root.cert_pem)}" % cfg.cluster_name,
            apiserver_cert_pem: "${base64encode(tls_locally_signed_cert.%s-master.cert_pem)}" % cfg.cluster_name,
            apiserver_key_pem: "${base64encode(tls_private_key.%s-master.private_key_pem)}" % cfg.cluster_name,
            master_kubeconfig: kubeconfig(cfg.cluster_name + "-master", "local", "service-account-context"),
            node_kubeconfig: kubeconfig(cfg.cluster_name + "-node", "local", "service-account-context"),
            master_ip: "${photon_virtual_machine.kubevm1.ip_address}",
            nodes_dns_mappings: std.join("\n", node_name_to_ip),
            flannel_net: cfg.photon.flannel_net,
            installer_container: config.phase2.installer_container,
            kubernetes_version: config.phase2.kubernetes_version, 
          },
        },
        configure_node: {
          template: "${file(\"configure-vm.sh\")}",
          vars: {
            role: "node",
            root_ca_public_pem: "${base64encode(tls_self_signed_cert.%s-root.cert_pem)}" % cfg.cluster_name,
            apiserver_cert_pem: "${base64encode(tls_locally_signed_cert.%s-master.cert_pem)}" % cfg.cluster_name,
            apiserver_key_pem: "${base64encode(tls_private_key.%s-master.private_key_pem)}" % cfg.cluster_name,
            master_kubeconfig: kubeconfig(cfg.cluster_name + "-master", "local", "service-account-context"),
            node_kubeconfig: kubeconfig(cfg.cluster_name + "-node", "local", "service-account-context"),
            master_ip: "${photon_virtual_machine.kubevm1.ip_address}",
            nodes_dns_mappings: std.join("\n", node_name_to_ip),
            flannel_net: cfg.photon.flannel_net,
            installer_container: config.phase2.installer_container,
            kubernetes_version: config.phase2.kubernetes_version,
          },
        },
        // Populates photon cloudprovider config file
        cloudprovider: {
          template: "${file(\"pc_cloud.conf\")}",
          vars: {
            url: cfg.photon.url,
            tenant: cfg.photon.tenant,
            project: cfg.photon.project,
          },
        },
      },
     },

    
    resource: {
      photon_virtual_machine: {
        ["kubevm" + vm]: {
            name: (if vm == 1 then "master" else ("node%d" % (vm-1))),
            tenant: cfg.photon.tenant,
            project: cfg.photon.project,
            flavor: cfg.photon.flavor,
            diskFlavor: cfg.photon.diskFlavor,
            diskName: "disk%d" % vm,
            image: cfg.photon.image,
            networks: cfg.photon.networks,
        } for vm in vms
      },
      null_resource: {
        master: {
            depends_on: master_dependency_list,
            connection: {
              user: vm_username,
              password: vm_password,
              host: "${photon_virtual_machine.kubevm1.ip_address}"
            },
            provisioner: [{
                "remote-exec": {
                  inline: [
                    "mkdir -p /etc/kubernetes/; echo '%s' > /etc/kubernetes/k8s_config.json " % (config_metadata_template % "master"),                    
                    "echo '%s' >  /etc/kubernetes/pc_cloud.conf" % "${data.template_file.cloudprovider.rendered}",            
                    "echo '%s' >>  /etc/kubernetes/pc_cloud.conf" % ["vmid = %s" % "${photon_virtual_machine.kubevm1.vmID}"],
                    "echo '%s' > /etc/configure-vm.sh; bash /etc/configure-vm.sh" % "${data.template_file.configure_master.rendered}",
                  ]
                }
           }, {
            "local-exec": {
              command: "echo '%s' > ./.tmp/kubeconfig.json" % kubeconfig(cfg.cluster_name + "-admin", cfg.cluster_name, cfg.cluster_name),
            },
           }],
        },} + {
        ["node" + vm]: {
            depends_on: ["photon_virtual_machine.kubevm1","photon_virtual_machine.kubevm%d" % vm],
            connection: {
              user: vm_username,
              password: vm_password,
              host: "${photon_virtual_machine.kubevm%d.ip_address}" % vm
            },
            provisioner: [{
                "remote-exec": {
                  inline: [
                    "mkdir -p /etc/kubernetes/; echo '%s' > /etc/kubernetes/k8s_config.json " % (config_metadata_template % "node"),                    
                    "echo '%s' > /etc/configure-vm.sh; bash /etc/configure-vm.sh" % "${data.template_file.configure_node.rendered}",
                    "echo '%s' >  /etc/kubernetes/pc_cloud.conf" % "${data.template_file.cloudprovider.rendered}",            
                    "echo '%s' >>  /etc/kubernetes/pc_cloud.conf" % ["vmid = %s" % ["${photon_virtual_machine.kubevm%d.vmID}" % vm]],
                  ]
                }
           }],
        } for vm in vms if vm > 1 },
    },    
  }, tf.pki.cluster_tls(cfg.cluster_name, ["%(cluster_name)s-master" % cfg], ["${photon_virtual_machine.kubevm1.ip_address}"]))
