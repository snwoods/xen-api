(*
 * Copyright (C) 2006-2012 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open API

(* A directory to use for temporary files. *)
let working_area = Filename.(concat (get_temp_dir_name ()) "xapi-test")

let make_uuid () = Uuidx.(to_string (make ()))

let assert_raises_api_error (code : string) ?(args : string list option)
    (f : unit -> 'a) : unit =
  try
    f () ;
    Alcotest.fail
      (Printf.sprintf "Function didn't raise expected API error %s" code)
  with Api_errors.Server_error (c, a) -> (
    Alcotest.check Alcotest.string "Function raised unexpected API error" code c ;
    match args with
    | None ->
        ()
    | Some args ->
        Alcotest.(check (list string))
          "Function raised API error with unexpected args" args a
  )

(* fields from Dundee *)
let default_cpu_info =
  [
    (* 0 - to avoid confusing test_pool_cpuinfo which creates new hosts and doesn't expect
     * localhost to be counted *)
    ("cpu_count", "0")
  ; ("socket_count", "0")
  ; ("threads_per_core", "0")
  ; ("vendor", "Abacus")
  ; ("speed", "")
  ; ("modelname", "")
  ; ("family", "")
  ; ("model", "")
  ; ("stepping", "")
  ; ("flags", "")
  ; ("features_pv", "")
  ; ("features_hvm", "")
  ; ("features_pv_host", "")
  ; ("features_hvm_host", "")
  ]

let cpu_policy_of_string = Xenops_interface.CPU_policy.of_string `host

let make_localhost ~__context ?(features = Features.all_features) () =
  let host_info =
    {
      Create_misc.name_label= "test host"
    ; xen_verstring= None
    ; linux_verstring= "something"
    ; hostname= "localhost"
    ; uuid= Xapi_inventory.lookup Xapi_inventory._installation_uuid
    ; dom0_uuid= Xapi_inventory.lookup Xapi_inventory._control_domain_uuid
    ; oem_manufacturer= None
    ; oem_model= None
    ; oem_build_number= None
    ; machine_serial_number= None
    ; machine_serial_name= None
    ; total_memory_mib= Some 1024L
    ; cpu_info=
        Some
          {
            cpu_count= 1
          ; socket_count= 1
          ; threads_per_core= 1
          ; vendor= ""
          ; speed= ""
          ; modelname= ""
          ; family= ""
          ; model= ""
          ; stepping= ""
          ; flags= ""
          ; features= cpu_policy_of_string ""
          ; features_pv= cpu_policy_of_string ""
          ; features_hvm= cpu_policy_of_string ""
          ; features_pv_host= cpu_policy_of_string ""
          ; features_hvm_host= cpu_policy_of_string ""
          }
    ; hypervisor= None
    ; chipset_info= None
    }
  in
  Dbsync_slave.create_localhost ~__context host_info ;
  (* We'd like to be able to call refresh_localhost_info, but
     	   create_misc is giving me too many headaches right now. Do the
     	   simple thing first and just set localhost_ref instead. *)
  (* Dbsync_slave.refresh_localhost_info ~__context host_info; *)
  Xapi_globs.localhost_ref := Helpers.get_localhost_uncached ~__context ;
  Db.Host.set_cpu_info ~__context ~self:!Xapi_globs.localhost_ref
    ~value:default_cpu_info ;
  Db.Host.remove_from_software_version ~__context
    ~self:!Xapi_globs.localhost_ref ~key:"network_backend" ;
  Db.Host.add_to_software_version ~__context ~self:!Xapi_globs.localhost_ref
    ~key:"network_backend"
    ~value:Network_interface.(string_of_kind Openvswitch) ;
  Create_misc.ensure_domain_zero_records ~__context
    ~host:!Xapi_globs.localhost_ref host_info ;
  Dbsync_master.create_pool_record ~__context ;
  let pool = Helpers.get_pool ~__context in
  Db.Pool.set_restrictions ~__context ~self:pool
    ~value:(Features.to_assoc_list features) ;
  Db.Pool.set_cpu_info ~__context ~self:pool ~value:default_cpu_info

(** Make a simple in-memory database containing a single host and dom0 VM record. *)
let make_test_database ?(conn = Mock.Database.conn) ?(reuse = false) ?features
    () =
  let __context = Mock.make_context_with_new_db ~conn ~reuse "mock" in
  Helpers.domain_zero_ref_cache := None ;
  make_localhost ~__context ?features () ;
  __context

let make_vm ~__context ?(name_label = "name_label")
    ?(name_description = "description") ?(user_version = 1L)
    ?(is_a_template = false) ?(affinity = Ref.null) ?(memory_target = 500L)
    ?(memory_static_max = 1000L) ?(memory_dynamic_max = 500L)
    ?(memory_dynamic_min = 500L) ?(memory_static_min = 0L) ?(vCPUs_params = [])
    ?(vCPUs_max = 1L) ?(vCPUs_at_startup = 1L)
    ?(actions_after_softreboot = `soft_reboot)
    ?(actions_after_shutdown = `destroy) ?(actions_after_reboot = `restart)
    ?(actions_after_crash = `destroy) ?(pV_bootloader = "") ?(pV_kernel = "")
    ?(pV_ramdisk = "") ?(pV_args = "") ?(pV_bootloader_args = "")
    ?(pV_legacy_args = "")
    ?(hVM_boot_policy = Constants.hvm_default_boot_policy)
    ?(hVM_boot_params = []) ?(hVM_shadow_multiplier = 1.) ?(platform = [])
    ?(pCI_bus = "") ?(other_config = []) ?(xenstore_data = [])
    ?(recommendations = "") ?(ha_always_run = false) ?(ha_restart_priority = "")
    ?(tags = []) ?(blocked_operations = []) ?(protection_policy = Ref.null)
    ?(is_snapshot_from_vmpp = false) ?(appliance = Ref.null) ?(start_delay = 0L)
    ?(snapshot_schedule = Ref.null) ?(is_vmss_snapshot = false)
    ?(shutdown_delay = 0L) ?(order = 0L) ?(suspend_SR = Ref.null)
    ?(suspend_VDI = Ref.null) ?(version = 0L) ?(generation_id = "0:0")
    ?(hardware_platform_version = 0L) ?has_vendor_device:_
    ?(has_vendor_device = false) ?(reference_label = "") ?(domain_type = `hvm)
    ?(nVRAM = []) ?(last_booted_record = "") ?(last_boot_CPU_flags = [])
    ?(power_state = `Halted) () =
  Xapi_vm.create ~__context ~name_label ~name_description ~user_version
    ~is_a_template ~affinity ~memory_target ~memory_static_max
    ~memory_dynamic_max ~memory_dynamic_min ~memory_static_min ~vCPUs_params
    ~vCPUs_max ~vCPUs_at_startup ~actions_after_softreboot
    ~actions_after_shutdown ~actions_after_reboot ~actions_after_crash
    ~pV_bootloader ~pV_kernel ~pV_ramdisk ~pV_args ~pV_bootloader_args
    ~pV_legacy_args ~hVM_boot_policy ~hVM_boot_params ~hVM_shadow_multiplier
    ~platform ~nVRAM ~pCI_bus ~other_config ~xenstore_data ~recommendations
    ~ha_always_run ~ha_restart_priority ~tags ~blocked_operations
    ~protection_policy ~is_snapshot_from_vmpp ~appliance ~start_delay
    ~shutdown_delay ~order ~suspend_SR ~suspend_VDI ~snapshot_schedule
    ~is_vmss_snapshot ~version ~generation_id ~hardware_platform_version
    ~has_vendor_device ~reference_label ~domain_type ~last_booted_record
    ~last_boot_CPU_flags ~power_state

let make_host ~__context ?(uuid = make_uuid ()) ?(name_label = "host")
    ?(name_description = "description") ?(hostname = "localhost")
    ?(address = "127.0.0.1") ?(external_auth_type = "")
    ?(external_auth_service_name = "") ?(external_auth_configuration = [])
    ?(license_params = []) ?(edition = "free") ?(license_server = [])
    ?(local_cache_sr = Ref.null) ?(chipset_info = []) ?(ssl_legacy = false)
    ?(last_software_update = Date.epoch) ?(last_update_hash = "")
    ?(ssh_enabled = true) ?(ssh_enabled_timeout = 0L) ?(ssh_expiry = Date.epoch)
    ?(console_idle_timeout = 0L) ?(ssh_auto_mode = false) () =
  let host =
    Xapi_host.create ~__context ~uuid ~name_label ~name_description ~hostname
      ~address ~external_auth_type ~external_auth_service_name
      ~external_auth_configuration ~license_params ~edition ~license_server
      ~local_cache_sr ~chipset_info ~ssl_legacy ~last_software_update
      ~last_update_hash ~ssh_enabled ~ssh_enabled_timeout ~ssh_expiry
      ~console_idle_timeout ~ssh_auto_mode
  in
  Db.Host.set_cpu_info ~__context ~self:host ~value:default_cpu_info ;
  host

let make_host2 ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "host") ?(name_description = "description")
    ?(hostname = "localhost") ?(address = "127.0.0.1")
    ?(external_auth_type = "") ?(external_auth_service_name = "")
    ?(external_auth_configuration = []) ?(license_params = [])
    ?(edition = "free") ?(license_server = []) ?(local_cache_sr = Ref.null)
    ?(chipset_info = []) ?(ssl_legacy = false) () =
  let pool = Helpers.get_pool ~__context in
  let tls_verification_enabled =
    Db.Pool.get_tls_verification_enabled ~__context ~self:pool
  in
  Db.Host.create ~__context ~ref ~current_operations:[] ~allowed_operations:[]
    ~software_version:(Xapi_globs.software_version ())
    ~https_only:false ~enabled:false
    ~aPI_version_major:Datamodel_common.api_version_major
    ~aPI_version_minor:Datamodel_common.api_version_minor
    ~aPI_version_vendor:Datamodel_common.api_version_vendor
    ~aPI_version_vendor_implementation:
      Datamodel_common.api_version_vendor_implementation ~name_description
    ~name_label ~uuid ~other_config:[] ~capabilities:[] ~cpu_configuration:[]
    ~cpu_info:[] ~chipset_info ~memory_overhead:0L ~sched_policy:"credit"
    ~supported_bootloaders:[] ~suspend_image_sr:Ref.null ~crash_dump_sr:Ref.null
    ~logging:[] ~hostname ~address ~metrics:Ref.null ~license_params
    ~boot_free_mem:0L ~ha_statefiles:[] ~ha_network_peers:[] ~blobs:[] ~tags:[]
    ~external_auth_type ~external_auth_service_name ~external_auth_configuration
    ~edition ~license_server ~bios_strings:[] ~power_on_mode:""
    ~power_on_config:[] ~local_cache_sr ~ssl_legacy ~guest_VCPUs_params:[]
    ~display:`enabled ~virtual_hardware_platform_versions:[]
    ~control_domain:Ref.null ~updates_requiring_reboot:[] ~iscsi_iqn:""
    ~multipathing:false ~uefi_certificates:"" ~editions:[] ~pending_guidances:[]
    ~tls_verification_enabled ~numa_affinity_policy:`default_policy
    ~last_software_update:(Xapi_host.get_servertime ~__context ~host:ref)
    ~recommended_guidances:[] ~latest_synced_updates_applied:`unknown
    ~pending_guidances_recommended:[] ~pending_guidances_full:[]
    ~last_update_hash:"" ~ssh_enabled:true ~ssh_enabled_timeout:0L
    ~ssh_expiry:Date.epoch ~console_idle_timeout:0L ~ssh_auto_mode:false ;
  ref

let make_pif ~__context ~network ~host ?(device = "eth0")
    ?(mAC = "C0:FF:EE:C0:FF:EE") ?(mTU = 1500L) ?(vLAN = -1L) ?(physical = true)
    ?(ip_configuration_mode = `None) ?(iP = "") ?(netmask = "") ?(gateway = "")
    ?(dNS = "") ?(bond_slave_of = Ref.null) ?(vLAN_master_of = Ref.null)
    ?(management = false) ?(other_config = []) ?(disallow_unplug = false)
    ?(ipv6_configuration_mode = `None) ?(iPv6 = []) ?(ipv6_gateway = "")
    ?(primary_address_type = `IPv4) ?(managed = true)
    ?(properties = [("gro", "on")]) () =
  Xapi_pif.pool_introduce ~__context ~device ~network ~host ~mAC ~mTU ~vLAN
    ~physical ~ip_configuration_mode ~iP ~netmask ~gateway ~dNS ~bond_slave_of
    ~vLAN_master_of ~management ~other_config ~disallow_unplug
    ~ipv6_configuration_mode ~iPv6 ~ipv6_gateway ~primary_address_type ~managed
    ~properties

let make_vlan ~__context ~tagged_PIF ~untagged_PIF ~tag ?(other_config = []) ()
    =
  Xapi_vlan.pool_introduce ~__context ~tagged_PIF ~untagged_PIF ~tag
    ~other_config

let make_network_sriov = Xapi_network_sriov.create_internal

let make_bond ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ()) ~master
    ?(other_config = []) ?(primary_slave = Ref.null) ?(mode = `activebackup)
    ?(properties = []) ?(auto_update_mac = false) () =
  Db.Bond.create ~__context ~ref ~uuid ~master ~other_config ~primary_slave
    ~mode ~properties ~links_up:0L ~auto_update_mac ;
  ref

let make_tunnel = Xapi_tunnel.create_internal ~protocol:`gre

let make_network ~__context ?(name_label = "net")
    ?(name_description = "description") ?(mTU = 1500L) ?(other_config = [])
    ?(bridge = "xenbr0") ?(managed = true) ?(purpose = []) () =
  Xapi_network.pool_introduce ~__context ~name_label ~name_description ~mTU
    ~other_config ~bridge ~managed ~purpose

let make_vif ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(current_operations = []) ?(allowed_operations = []) ?(reserved = false)
    ?(device = "") ?(network = Ref.null) ?(vM = Ref.null)
    ?(mAC = "00:00:00:00:00:00") ?(mAC_autogenerated = false) ?(mTU = 1500L)
    ?(qos_algorithm_type = "") ?(qos_algorithm_params = [])
    ?(qos_supported_algorithms = []) ?(currently_attached = false)
    ?(status_code = 0L) ?(status_detail = "") ?(runtime_properties = [])
    ?(other_config = []) ?(metrics = Ref.null) ?(locking_mode = `unlocked)
    ?(ipv4_allowed = []) ?(ipv6_allowed = []) ?(ipv4_configuration_mode = `None)
    ?(ipv4_addresses = []) ?(ipv4_gateway = "")
    ?(ipv6_configuration_mode = `None) ?(ipv6_addresses = [])
    ?(ipv6_gateway = "") () =
  Db.VIF.create ~__context ~ref ~uuid ~current_operations ~allowed_operations
    ~reserved ~device ~network ~vM ~mAC ~mAC_autogenerated ~mTU
    ~qos_algorithm_type ~qos_algorithm_params ~qos_supported_algorithms
    ~currently_attached ~status_code ~status_detail ~runtime_properties
    ~other_config ~metrics ~locking_mode ~ipv4_allowed ~ipv6_allowed
    ~ipv4_configuration_mode ~ipv4_addresses ~ipv4_gateway
    ~ipv6_configuration_mode ~ipv6_addresses ~ipv6_gateway
    ~reserved_pci:Ref.null ;
  ref

let make_pool ~__context ~master ?(name_label = "") ?(name_description = "")
    ?(default_SR = Ref.null) ?(suspend_image_SR = Ref.null)
    ?(crash_dump_SR = Ref.null) ?(ha_enabled = false) ?(ha_configuration = [])
    ?(ha_statefiles = []) ?(ha_host_failures_to_tolerate = 0L)
    ?(ha_plan_exists_for = 0L) ?(ha_allow_overcommit = false)
    ?(ha_overcommitted = false) ?(blobs = []) ?(tags = []) ?(gui_config = [])
    ?(health_check_config = []) ?(wlb_url = "") ?(wlb_username = "")
    ?(wlb_password = Ref.null) ?(wlb_enabled = false) ?(wlb_verify_cert = false)
    ?(redo_log_enabled = false) ?(redo_log_vdi = Ref.null)
    ?(vswitch_controller = "") ?(igmp_snooping_enabled = false)
    ?(restrictions = []) ?(current_operations = []) ?(allowed_operations = [])
    ?(other_config = [Xapi_globs.memory_ratio_hvm; Xapi_globs.memory_ratio_pv])
    ?(ha_cluster_stack = !Xapi_globs.cluster_stack_default)
    ?(guest_agent_config = []) ?(cpu_info = [])
    ?(policy_no_vendor_device = false) ?(live_patching_disabled = false)
    ?(uefi_certificates = "") ?(custom_uefi_certificates = "")
    ?(repositories = []) ?(client_certificate_auth_enabled = false)
    ?(client_certificate_auth_name = "") ?(repository_proxy_url = "")
    ?(repository_proxy_username = "") ?(repository_proxy_password = Ref.null)
    ?(migration_compression = false) ?(coordinator_bias = true)
    ?(telemetry_uuid = Ref.null) ?(telemetry_frequency = `weekly)
    ?(telemetry_next_collection = API.Date.epoch)
    ?(last_update_sync = API.Date.epoch) ?(update_sync_frequency = `daily)
    ?(update_sync_day = 0L) ?(update_sync_enabled = false)
    ?(recommendations = []) ?(license_server = [])
    ?(ha_reboot_vm_on_internal_shutdown = true) () =
  let pool_ref = Ref.make () in
  Db.Pool.create ~__context ~ref:pool_ref ~uuid:(make_uuid ()) ~name_label
    ~name_description ~master ~default_SR ~suspend_image_SR ~crash_dump_SR
    ~ha_enabled ~ha_configuration ~ha_statefiles ~ha_host_failures_to_tolerate
    ~ha_plan_exists_for ~ha_allow_overcommit ~ha_overcommitted ~blobs ~tags
    ~gui_config ~health_check_config ~wlb_url ~wlb_username ~wlb_password
    ~wlb_enabled ~wlb_verify_cert ~redo_log_enabled ~redo_log_vdi
    ~vswitch_controller ~igmp_snooping_enabled ~current_operations
    ~allowed_operations ~restrictions ~other_config ~ha_cluster_stack
    ~guest_agent_config ~cpu_info ~policy_no_vendor_device
    ~live_patching_disabled ~uefi_certificates ~custom_uefi_certificates
    ~is_psr_pending:false ~tls_verification_enabled:false ~repositories
    ~client_certificate_auth_enabled ~client_certificate_auth_name
    ~repository_proxy_url ~repository_proxy_username ~repository_proxy_password
    ~migration_compression ~coordinator_bias ~telemetry_uuid
    ~telemetry_frequency ~telemetry_next_collection ~last_update_sync
    ~local_auth_max_threads:8L ~ext_auth_max_threads:8L
    ~ext_auth_cache_enabled:false ~ext_auth_cache_size:50L
    ~ext_auth_cache_expiry:300L ~update_sync_frequency ~update_sync_day
    ~update_sync_enabled ~recommendations ~license_server
    ~ha_reboot_vm_on_internal_shutdown ;
  pool_ref

let default_sm_features =
  [
    ("SR_PROBE", 1L)
  ; ("SR_UPDATE", 1L)
  ; ("VDI_CREATE", 1L)
  ; ("VDI_DELETE", 1L)
  ; ("VDI_ATTACH", 1L)
  ; ("VDI_DETACH", 1L)
  ; ("VDI_UPDATE", 1L)
  ; ("VDI_CLONE", 1L)
  ; ("VDI_SNAPSHOT", 1L)
  ; ("VDI_RESIZE", 1L)
  ; ("VDI_GENERATE_CONFIG", 1L)
  ; ("VDI_RESET_ON_BOOT", 2L)
  ; ("VDI_CONFIG_CBT", 1L)
  ]

let make_sm ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(_type = "sm") ?(name_label = "") ?(name_description = "") ?(vendor = "")
    ?(copyright = "") ?(version = "") ?(required_api_version = "")
    ?(capabilities = []) ?(features = default_sm_features)
    ?(host_pending_features = []) ?(configuration = []) ?(other_config = [])
    ?(driver_filename = "/dev/null") ?(required_cluster_stack = []) () =
  Db.SM.create ~__context ~ref ~uuid ~_type ~name_label ~name_description
    ~vendor ~copyright ~version ~required_api_version ~capabilities ~features
    ~host_pending_features ~configuration ~other_config ~driver_filename
    ~required_cluster_stack ;
  ref

let make_sr ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(allowed_operations = [])
    ?(current_operations = []) ?(virtual_allocation = 0L)
    ?(physical_utilisation = 0L) ?(physical_size = 0L) ?(_type = "sm")
    ?(content_type = "") ?(shared = true) ?(other_config = []) ?(tags = [])
    ?(default_vdi_visibility = true) ?(sm_config = []) ?(blobs = [])
    ?(local_cache_enabled = false) ?(introduced_by = Ref.make ())
    ?(clustered = false) ?(is_tools_sr = false) () =
  Db.SR.create ~__context ~ref ~uuid ~name_label ~name_description
    ~allowed_operations ~current_operations ~virtual_allocation
    ~physical_utilisation ~physical_size ~_type ~content_type ~shared
    ~other_config ~tags ~default_vdi_visibility ~sm_config ~blobs
    ~local_cache_enabled ~introduced_by ~clustered ~is_tools_sr ;
  ref

let make_pbd ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(host = Ref.make ()) ?(sR = Ref.make ()) ?(device_config = [])
    ?(currently_attached = true) ?(other_config = []) () =
  Db.PBD.create ~__context ~ref ~uuid ~host ~sR ~device_config
    ~currently_attached ~other_config ;
  ref

let make_vbd ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(allowed_operations = []) ?(current_operations = []) ?(vM = Ref.make ())
    ?(vDI = Ref.make ()) ?(device = "") ?(userdevice = "") ?(bootable = true)
    ?(mode = `RW) ?(_type = `Disk) ?(unpluggable = false)
    ?(storage_lock = false) ?(empty = false) ?(reserved = false)
    ?(other_config = []) ?(currently_attached = false) ?(status_code = 0L)
    ?(status_detail = "") ?(runtime_properties = []) ?(qos_algorithm_type = "")
    ?(qos_algorithm_params = []) ?(qos_supported_algorithms = [])
    ?(metrics = Ref.make ()) () =
  Db.VBD.create ~__context ~ref ~uuid ~allowed_operations ~current_operations
    ~vM ~vDI ~device ~userdevice ~bootable ~mode ~_type ~unpluggable
    ~storage_lock ~empty ~reserved ~other_config ~currently_attached
    ~status_code ~status_detail ~runtime_properties ~qos_algorithm_type
    ~qos_algorithm_params ~qos_supported_algorithms ~metrics ;
  ref

let make_vdi ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(allowed_operations = [])
    ?(current_operations = []) ?(sR = Ref.make ()) ?(virtual_size = 0L)
    ?(physical_utilisation = 0L) ?(_type = `user) ?(sharable = false)
    ?(read_only = false) ?(other_config = []) ?(storage_lock = false)
    ?(location = "") ?(managed = false) ?(missing = false) ?(parent = Ref.null)
    ?(xenstore_data = []) ?(sm_config = []) ?(is_a_snapshot = false)
    ?(snapshot_of = Ref.null) ?(snapshot_time = API.Date.epoch) ?(tags = [])
    ?(allow_caching = true) ?(on_boot = `persist)
    ?(metadata_of_pool = Ref.make ()) ?(metadata_latest = true)
    ?(is_tools_iso = false) ?(cbt_enabled = false) () =
  Db.VDI.create ~__context ~ref ~uuid ~name_label ~name_description
    ~allowed_operations ~current_operations ~sR ~virtual_size
    ~physical_utilisation ~_type ~sharable ~read_only ~other_config
    ~storage_lock ~location ~managed ~missing ~parent ~xenstore_data ~sm_config
    ~is_a_snapshot ~snapshot_of ~snapshot_time ~tags ~allow_caching ~on_boot
    ~metadata_of_pool ~metadata_latest ~is_tools_iso ~cbt_enabled ;
  ref

let make_pci ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(class_id = "") ?(class_name = "") ?(vendor_id = "") ?(vendor_name = "")
    ?(device_id = "") ?(device_name = "") ?(host = Ref.null)
    ?(pci_id = "0000:00:00.0") ?(functions = 0L) ?(physical_function = Ref.null)
    ?(dependencies = []) ?(other_config = []) ?(subsystem_vendor_id = "")
    ?(subsystem_vendor_name = "") ?(subsystem_device_id = "")
    ?(subsystem_device_name = "") ?(driver_name = "")
    ?(scheduled_to_be_attached_to = Ref.null) () =
  Db.PCI.create ~__context ~ref ~uuid ~class_id ~class_name ~vendor_id
    ~vendor_name ~device_id ~device_name ~host ~pci_id ~functions
    ~physical_function ~dependencies ~other_config ~subsystem_vendor_id
    ~subsystem_vendor_name ~subsystem_device_id ~driver_name
    ~subsystem_device_name ~scheduled_to_be_attached_to ;
  ref

let make_pgpu ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(pCI = Ref.null) ?(gPU_group = Ref.null) ?(host = Ref.null)
    ?(other_config = []) ?(size = Constants.pgpu_default_size)
    ?(supported_VGPU_types = []) ?(enabled_VGPU_types = [])
    ?(supported_VGPU_max_capacities = []) ?(dom0_access = `enabled)
    ?(is_system_display_device = false) () =
  Db.PGPU.create ~__context ~ref ~uuid ~pCI ~gPU_group ~host ~other_config ~size
    ~supported_VGPU_max_capacities ~dom0_access ~is_system_display_device
    ~compatibility_metadata:[] ;
  Db.PGPU.set_supported_VGPU_types ~__context ~self:ref
    ~value:supported_VGPU_types ;
  Db.PGPU.set_enabled_VGPU_types ~__context ~self:ref ~value:enabled_VGPU_types ;
  ref

let make_gpu_group ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(gPU_types = [])
    ?(other_config = []) ?(allocation_algorithm = `depth_first) () =
  Db.GPU_group.create ~__context ~ref ~uuid ~name_label ~name_description
    ~gPU_types ~other_config ~allocation_algorithm ;
  ref

let make_vgpu ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(vM = Ref.null) ?(gPU_group = Ref.null) ?(device = "0")
    ?(currently_attached = false) ?(other_config = []) ?(_type = Ref.null)
    ?(resident_on = Ref.null) ?(scheduled_to_be_resident_on = Ref.null)
    ?(compatibility_metadata = []) ?(extra_args = "") ?(pCI = Ref.null) () =
  Db.VGPU.create ~__context ~ref ~uuid ~vM ~gPU_group ~device
    ~currently_attached ~other_config ~_type ~resident_on
    ~scheduled_to_be_resident_on ~compatibility_metadata ~extra_args ~pCI ;
  ref

let make_vgpu_type ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(vendor_name = "") ?(model_name = "") ?(framebuffer_size = 0L)
    ?(max_heads = 0L) ?(max_resolution_x = 0L) ?(max_resolution_y = 0L)
    ?(size = 0L) ?(internal_config = []) ?(implementation = `passthrough)
    ?(identifier = "") ?(experimental = false)
    ?(compatible_model_names_in_vm = []) ?(compatible_model_names_on_pgpu = [])
    () =
  let compatible_types_in_vm = compatible_model_names_in_vm in
  let compatible_types_on_pgpu = compatible_model_names_on_pgpu in
  Db.VGPU_type.create ~__context ~ref ~uuid ~vendor_name ~model_name
    ~framebuffer_size ~max_heads ~max_resolution_x ~max_resolution_y ~size
    ~internal_config ~implementation ~identifier ~experimental
    ~compatible_types_in_vm ~compatible_types_on_pgpu ;
  ref

let make_pvs_site ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(pVS_uuid = "")
    ?(cache_storage = []) () =
  Db.PVS_site.create ~__context ~ref ~uuid ~name_label ~name_description
    ~pVS_uuid ~cache_storage ;
  ref

let make_pvs_proxy ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(site = Ref.null) ?(vIF = Ref.null) ?(currently_attached = false)
    ?(status = `stopped) () =
  Db.PVS_proxy.create ~__context ~ref ~uuid ~site ~vIF ~currently_attached
    ~status ;
  ref

let make_pvs_server ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(addresses = []) ?(first_port = 1L) ?(last_port = 65535L)
    ?(site = Ref.null) () =
  Db.PVS_server.create ~__context ~addresses ~ref ~uuid ~first_port ~last_port
    ~site ;
  ref

let make_pvs_cache_storage ~__context ?(ref = Ref.make ())
    ?(uuid = make_uuid ()) ?(host = Ref.null) ?(sR = Ref.null)
    ?(site = Ref.null) ?(size = 0L) ?(vDI = Ref.null) () =
  Db.PVS_cache_storage.create ~__context ~ref ~uuid ~host ~sR ~site ~size ~vDI ;
  ref

let make_pool_update ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(version = "")
    ?(installation_size = 0L) ?(key = "") ?(after_apply_guidance = [])
    ?(enforce_homogeneity = false) ?other_config:_ ?(vdi = Ref.null) () =
  let update_info =
    Xapi_pool_update.
      {
        uuid
      ; name_label
      ; name_description
      ; version
      ; key= (match key with "" -> None | s -> Some s)
      ; installation_size
      ; after_apply_guidance
      ; enforce_homogeneity
      }
  in

  Xapi_pool_update.create_update_record ~__context ~update:ref ~update_info ~vdi ;
  ref

let make_session ~__context ?(ref = Ref.make_secret ()) ?(uuid = make_uuid ())
    ?(this_host = Ref.null) ?(this_user = Ref.null)
    ?(last_active = API.Date.epoch) ?(pool = false) ?(other_config = [])
    ?(is_local_superuser = false) ?(subject = Ref.null)
    ?(validation_time = API.Date.epoch) ?(auth_user_sid = "")
    ?(auth_user_name = "") ?(rbac_permissions = []) ?(parent = Ref.null)
    ?(originator = "test") ?(client_certificate = false) () =
  Db.Session.create ~__context ~ref ~uuid ~this_host ~this_user ~last_active
    ~pool ~other_config ~is_local_superuser ~subject ~validation_time
    ~auth_user_sid ~auth_user_name ~rbac_permissions ~parent ~originator
    ~client_certificate ;
  ref

let create_physical_pif ~__context ~host ?network ?(bridge = "xapi0")
    ?(managed = true) () =
  let network =
    match network with
    | Some network ->
        network
    | None ->
        make_network ~__context ~bridge ()
  in
  make_pif ~__context ~network ~host ~managed ()

let create_vlan_pif ~__context ~host ~vlan ~pif ?(bridge = "xapi0") () =
  let network = make_network ~__context ~bridge () in
  let vlan_pif =
    make_pif ~__context ~network ~host ~vLAN:vlan ~physical:false ()
  in
  let _ =
    make_vlan ~__context ~tagged_PIF:pif ~untagged_PIF:vlan_pif ~tag:vlan ()
  in
  vlan_pif

let create_tunnel_pif ~__context ~host ~pif ?(bridge = "xapi0") () =
  let network = make_network ~__context ~bridge () in
  let _, access_pif =
    make_tunnel ~__context ~transport_PIF:pif ~network ~host
  in
  access_pif

let create_sriov_pif ~__context ~pif ?network ?(bridge = "xapi0") () =
  let sriov_network =
    match network with
    | Some network ->
        network
    | None ->
        make_network ~__context ~bridge ()
  in
  let physical_rec = Db.PIF.get_record ~__context ~self:pif in
  let sriov, sriov_logical_pif =
    make_network_sriov ~__context ~physical_PIF:pif ~physical_rec
      ~network:sriov_network
  in
  Db.Network_sriov.set_configuration_mode ~__context ~self:sriov ~value:`sysfs ;
  sriov_logical_pif

let create_bond_pif ~__context ~host ~members ?(bridge = "xapi0") () =
  let network = make_network ~__context ~bridge () in
  let bond_master = make_pif ~__context ~network ~host ~physical:false () in
  let bond = make_bond ~__context ~master:bond_master () in
  List.iter
    (fun member -> Db.PIF.set_bond_slave_of ~__context ~self:member ~value:bond)
    members ;
  bond_master

let mknlist n f =
  let rec aux result = function
    | 0 ->
        result
    | n ->
        let result = f () :: result in
        aux result (n - 1)
  in
  aux [] n

let make_vfs_on_pf ~__context ~pf ~num =
  let rec make_vf num =
    if num > 0L then (
      let vf = make_pci ~__context ~functions:1L () in
      Db.PCI.set_physical_function ~__context ~self:vf ~value:pf ;
      let functions = Db.PCI.get_functions ~__context ~self:pf in
      Db.PCI.set_functions ~__context ~self:pf ~value:(Int64.add functions 1L) ;
      make_vf (Int64.sub num 1L)
    )
  in
  make_vf num

let make_cluster_host ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(cluster = Ref.null) ?(host = Ref.null) ?(pIF = Ref.null) ?(enabled = true)
    ?(joined = true) ?(live = true) ?(last_update_live = Date.epoch)
    ?(allowed_operations = []) ?(current_operations = []) ?(other_config = [])
    () =
  Db.Cluster_host.create ~__context ~ref ~uuid ~cluster ~host ~pIF ~enabled
    ~allowed_operations ~current_operations ~other_config ~joined ~live
    ~last_update_live ;
  ref

let make_cluster_and_cluster_host ~__context ?(ref = Ref.make ())
    ?(uuid = make_uuid ()) ?(cluster_token = "") ?(pIF = Ref.null)
    ?(cluster_stack = Constants.default_smapiv3_cluster_stack)
    ?(cluster_stack_version = 3L) ?(allowed_operations = [])
    ?(current_operations = []) ?(pool_auto_join = true)
    ?(token_timeout = Constants.default_token_timeout_s)
    ?(token_timeout_coefficient = Constants.default_token_timeout_coefficient_s)
    ?(cluster_config = []) ?(other_config = []) ?(host = Ref.null)
    ?(is_quorate = false) ?(quorum = 0L) ?(live_hosts = 0L)
    ?(expected_hosts = 0L) () =
  Db.Cluster.create ~__context ~ref ~uuid ~cluster_token ~pending_forget:[]
    ~cluster_stack ~cluster_stack_version ~allowed_operations
    ~current_operations ~pool_auto_join ~token_timeout
    ~token_timeout_coefficient ~cluster_config ~other_config ~is_quorate ~quorum
    ~live_hosts ~expected_hosts ;
  let cluster_host_ref =
    make_cluster_host ~__context ~cluster:ref ~host ~pIF ()
  in
  (ref, cluster_host_ref)

let make_cluster_and_hosts ~__context extra_hosts =
  let cluster_stack = "mock_cluster_stack" in
  let network = make_network ~__context () in
  let host = Helpers.get_localhost ~__context in
  let pIF = make_pif ~__context ~network ~host ~iP:"192.0.2.1" () in
  let cluster, cluster_host =
    make_cluster_and_cluster_host ~__context ~cluster_stack ~pIF ~host ()
  in
  let build_cluster_host i host =
    let pIF =
      make_pif ~__context ~network ~host
        ~iP:(Printf.sprintf "192.0.2.%d" (i + 2))
        ()
    in
    make_cluster_host ~__context ~cluster ~host ~pIF ()
  in
  (cluster, cluster_host :: List.mapi build_cluster_host extra_hosts)

let make_observer ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "") ?(name_description = "") ?(hosts = []) ?(enabled = false)
    ?(attributes = []) ?(endpoints = []) ?(components = []) () =
  Db.Observer.create ~__context ~ref ~uuid ~name_label ~name_description ~hosts
    ~attributes ~endpoints ~components ~enabled ;
  ref

let make_vm_group ~__context ?(ref = Ref.make ()) ?(uuid = make_uuid ())
    ?(name_label = "vm_group") ?(name_description = "") ?(placement = `normal)
    () =
  Db.VM_group.create ~__context ~ref ~uuid ~name_label ~name_description
    ~placement ;
  ref
