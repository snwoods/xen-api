open Rpc
open Idl

module type COMPONENT_ERROR = sig
  type comp_error

  val err : comp_error Error.t
end

module ObserverAPI (R : RPC) (ComponentError : COMPONENT_ERROR) = struct
  open R
  open TypeCombinators

  let dbg_p = Param.mk ~name:"dbg" Types.string

  let unit_p = Param.mk ~name:"unit" Types.unit

  let endpoints_p = Param.mk ~name:"endpoints" (list Types.string)

  let bool_p = Param.mk ~name:"bool" Types.bool

  let uuid_p = Param.mk ~name:"uuid" Types.string

  let name_label_p = Param.mk ~name:"name_label" Types.string

  let dict_p = Param.mk ~name:"dict" dict

  let string_p = Param.mk ~name:"string" Types.string

  let int_p = Param.mk ~name:"int" Types.int

  let float_p = Param.mk ~name:"float" Types.float

  let create =
    declare "Observer.create" []
      (dbg_p
      @-> uuid_p
      @-> name_label_p
      @-> dict_p
      @-> endpoints_p
      @-> bool_p
      @-> returning unit_p ComponentError.err
      )

  let destroy =
    declare "Observer.destroy" []
      (dbg_p @-> uuid_p @-> returning unit_p ComponentError.err)

  let set_enabled =
    declare "Observer.set_enabled" []
      (dbg_p @-> uuid_p @-> bool_p @-> returning unit_p ComponentError.err)

  let set_attributes =
    declare "Observer.set_attributes" []
      (dbg_p @-> uuid_p @-> dict_p @-> returning unit_p ComponentError.err)

  let set_endpoints =
    declare "Observer.set_endpoints" []
      (dbg_p @-> uuid_p @-> endpoints_p @-> returning unit_p ComponentError.err)

  let init =
    declare "Observer.init" [] (dbg_p @-> returning unit_p ComponentError.err)

  let set_trace_log_dir =
    declare "Observer.set_trace_log_dir" []
      (dbg_p @-> string_p @-> returning unit_p ComponentError.err)

  let set_export_interval =
    declare "Observer.set_export_interval" []
      (dbg_p @-> float_p @-> returning unit_p ComponentError.err)

  let set_max_spans =
    declare "Observer.set_max_spans" []
      (dbg_p @-> int_p @-> returning unit_p ComponentError.err)

  let set_max_traces =
    declare "Observer.set_max_traces" []
      (dbg_p @-> int_p @-> returning unit_p ComponentError.err)

  let set_max_file_size =
    declare "Observer.set_max_file_size" []
      (dbg_p @-> int_p @-> returning unit_p ComponentError.err)

  let set_host_id =
    declare "Observer.set_host_id" []
      (dbg_p @-> string_p @-> returning unit_p ComponentError.err)

  let set_compress_tracing_files =
    declare "Observer.set_compress_tracing_files" []
      (dbg_p @-> bool_p @-> returning unit_p ComponentError.err)
end
