module type COMPONENT_ERROR = sig
  type comp_error

  val err : comp_error Idl.Error.t
end

module ObserverAPI : functor
  (R : Idl.RPC)
  (ComponentError : COMPONENT_ERROR)
  -> sig
  val dbg_p : string Idl.Param.t

  val unit_p : unit Idl.Param.t

  val endpoints_p : string list Idl.Param.t

  val bool_p : bool Idl.Param.t

  val uuid_p : string Idl.Param.t

  val name_label_p : string Idl.Param.t

  val dict_p : (string * string) list Idl.Param.t

  val string_p : string Idl.Param.t

  val int_p : int Idl.Param.t

  val float_p : float Idl.Param.t

  val create :
    (   string
     -> string
     -> string
     -> (string * string) list
     -> string list
     -> bool
     -> (unit, ComponentError.comp_error) R.comp
    )
    R.res

  val destroy :
    (string -> string -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_enabled :
    (string -> string -> bool -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_attributes :
    (   string
     -> string
     -> (string * string) list
     -> (unit, ComponentError.comp_error) R.comp
    )
    R.res

  val set_endpoints :
    (string -> string -> string list -> (unit, ComponentError.comp_error) R.comp)
    R.res

  val init : (string -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_trace_log_dir :
    (string -> string -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_export_interval :
    (string -> float -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_max_spans :
    (string -> int -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_max_traces :
    (string -> int -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_max_file_size :
    (string -> int -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_host_id :
    (string -> string -> (unit, ComponentError.comp_error) R.comp) R.res

  val set_compress_tracing_files :
    (string -> bool -> (unit, ComponentError.comp_error) R.comp) R.res
end
