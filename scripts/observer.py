#!/usr/bin/python3

configs = []

debug_enabled = True

import logging
from logging.handlers import SysLogHandler
FORMAT = "observer.py: %(message)s"
handler = SysLogHandler(facility='local5', address='/dev/log')
logging.basicConfig(format=FORMAT, handlers=[handler])
syslog = logging.getLogger(__name__)
if debug_enabled:
  syslog.setLevel(logging.DEBUG)
else:
  syslog.setLevel(logging.INFO)
#TODO I seriously don't know why the below isn't working, it's almost exactly what log.py does
#handler.setFormatter(logging.Formatter(FORMAT))
#syslog.addHandler(logging.handlers.SysLogHandler(facility='local5', address='/dev/log'))
debug = syslog.debug # syslog.debug("%(message)s", msg)

try: 
  import os
  # there can be many observer config files in the configuration directory
  observer_conf_dir = "/etc/xensource/observer/smapi/enabled/" #os.getenv("OBSERVER_CONF_DIR", default=".")
  configs = [(observer_conf_dir+"/"+f) for f in os.listdir(observer_conf_dir) if os.path.isfile(os.path.join(observer_conf_dir, f)) and f.endswith("observer.conf")] 
except Exception as e:
  #print("conf_dir="+str(e))
  #TODO: syslog error
  pass

# noop decorator
def span(wrapped=None):
  return wrapped

# noop patch_module
def patch_module(module_name):
  pass

debug("configs="+str(configs))
# do not do anything unless configuration files have been found
if configs:

  tracers = []

  from opentelemetry import trace
  from opentelemetry.sdk.resources import Resource
  from opentelemetry.sdk.trace import TracerProvider
  from opentelemetry.sdk.trace.export import BatchSpanProcessor
  from opentelemetry.sdk.trace.export import ConsoleSpanExporter
  from opentelemetry.exporter.zipkin.json import ZipkinExporter
  from opentelemetry.baggage.propagation import W3CBaggagePropagator
  from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

  import configparser
  import os


  def kvs_of_config(path,header="default"):
    cfg = configparser.ConfigParser()
    with open(path) as config_file:
      cfg.read_string(f"[{header}]\n" + config_file.read()) 
    kvs = dict(cfg[header])
    debug(path+":kvs="+str(kvs))
    return kvs

  kvs_all_conf=kvs_of_config(observer_conf_dir+"/all.conf")
  module_names=kvs_all_conf.get("module_names", "LVHDSR,XenAPI,SR,SRCommand,util").split(",")
  debug("module_names="+str(module_names))
  #module_names = [
  #  "LVHDSR",
  #  "XenAPI",
  #  "SR",
  #  "SRCommand",
  #  "util",
  #  #"blktap2", #auto-instrumentation currently crashes with infinite recursion in __repr__
  #]

  def tracer_of_config(path):
    otelvars='https://opentelemetry-python.readthedocs.io/en/latest/sdk/environment_variables.html'
    argkv=kvs_of_config(path,header=otelvars)
    config_otel_resource_attributes = argkv.get("otel_resource_attributes", "")
    if config_otel_resource_attributes:
      # OTEL requires some attributes e.g. service.name to be in the environment variable
      os.environ["OTEL_RESOURCE_ATTRIBUTES"] = config_otel_resource_attributes
    trace_log_dir_base = argkv.get("trace_log_dir_base", "/var/log/dt/")
    otel_exporter_zipkin_endpoint = argkv.get("otel_exporter_zipkin_endpoint")
    otel_resource_attributes = dict(item.split("=") for item in argkv.get("otel_resource_attributes", "").split(",") if "=" in item)
    # internal SM default attributes
    service_name=argkv.get("otel_service_name", otel_resource_attributes.get("service.name", "unknown") )
    
    host_uuid=otel_resource_attributes.get("xs.host.uuid", "unknown")
    tracestate=argkv.get("tracestate", "unknown")
  
    from typing import Sequence
    from opentelemetry.sdk.trace.export import SpanExportResult
    from opentelemetry.trace import Span
    from datetime import datetime, timezone
    basedir = trace_log_dir_base + "/zipkinv2/json/"
    #eg.:"/var/log/dt/zipkinv2/json/xapi-6ddf2ff7-cdf7-479d-a943-ad8776c3fcf7-2023-11-09T18:39:53.322802-00:00.ndjson"
    bugtool_filenamer = lambda: basedir + service_name + "-" + host_uuid + "-" + tracestate + "-" + datetime.now(timezone.utc).isoformat() + ".ndjson" #rfc3339
    debug("filenamer="+bugtool_filenamer())
    class FileZipkinExporter(ZipkinExporter):
      def __init__(self, *args, **kwargs):
        self.bugtool_filename = bugtool_filenamer() 
        self.written_so_far_in_file = 0
        debug("FileZipkinExporter="+str(self))
        super().__init__(*args, **kwargs)
      # https://github.com/open-telemetry/opentelemetry-python/blob/main/exporter/opentelemetry-exporter-zipkin-json/src/opentelemetry/exporter/zipkin/json/__init__.py#L152
      def export(self, spans: Sequence[Span]) -> SpanExportResult:
        data=self.encoder.serialize(spans, self.local_node)
        datastr=str(data)
        debug("data.type="+str(type(data))+",data.len="+str(len(datastr)))
        debug("data="+datastr)
        with open(self.bugtool_filename,'a') as bugtool_file:
          bugtool_file.write(datastr+"\n") #ndjson
        self.written_so_far_in_file += len(data)
        if self.written_so_far_in_file > 1024*1024:
          #TODO:compress current bugtool_filename using zstd (or write it in compressed format)
          self.bugtool_filename = bugtool_filenamer()
          self.written_so_far_in_file = 0
        return SpanExportResult.SUCCESS

    traceparent = os.getenv("TRACEPARENT", None)
    traceparent = traceparent[:-1] + "1"
    debug(f"Traceparent: {traceparent}")
    propagator = TraceContextTextMapPropagator()
    traceparent_carrier = { "traceparent": traceparent }
    context_with_traceparent = propagator.extract(traceparent_carrier)
    from opentelemetry.context import attach
    attach(context_with_traceparent)

    provider = TracerProvider(
      resource=Resource.create(
         #{
         #       "service.name": "shoppingcart",
         #       "service.instance.id": "instance-12",
         #   }
        # w3c baggage format:
        # https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md#specifying-resource-information-via-an-environment-variable
        W3CBaggagePropagator().extract(
          {},
          # externally-provided SM attributes
          # TODO: only if otel_resource_attributes exists
          otel_resource_attributes
        )
      )
    )
    #processor_console = BatchSpanProcessor(ConsoleSpanExporter())
    #provider.add_span_processor(processor_console)
    processor_filezipkin = BatchSpanProcessor(FileZipkinExporter())
    provider.add_span_processor(processor_filezipkin)
    if otel_exporter_zipkin_endpoint:
      processor_zipkin  = BatchSpanProcessor(ZipkinExporter(
        # https://opentelemetry-python.readthedocs.io/en/latest/exporter/zipkin/zipkin.html
        endpoint = otel_exporter_zipkin_endpoint
      ))
      provider.add_span_processor(processor_zipkin)

    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer(__name__)
    return tracer

  def get_tracers():
    try:
      tracers = list(map(tracer_of_config, configs))
      return tracers
    except Exception as e:
      #print("get_tracers="+str(e))
      return []

  tracers = get_tracers()
  #print("tracers="+str(tracers))
  debug("tracers="+str(tracers))

  # public decorator that creates a trace around a function func
  # and then clones the returned span for each of the existing traces.
  import traceback
  import wrapt
  import inspect
  import functools
  import sys

  def span_of_tracers(wrapped=None, span_name_prefix=""):
    #print("wrapped.type="+str(type(wrapped)))
    if wrapped is None: # handle decorators without parameters
        return functools.partial(span_of_tracers, span_name_prefix=span_name_prefix)

    @wrapt.decorator
    def wrapper(wrapped, instance, args, kwargs):
      span_name = None
      span_attributes = None
      if not tracers or tracers == []:
        return wrapped(*args, **kwargs)
      else:
        if not span_name:
          module_name = wrapped.__module__ if hasattr(wrapped, "__module__") else ""
          qual_name = wrapped.__qualname__ if hasattr(wrapped, "__qualname__") else ""
          span_name = ((span_name_prefix + ":") if span_name_prefix else "") + module_name + ':' + qual_name
          if not module_name and not qual_name:
            span_name = str(wrapped)
        if not span_attributes:
          span_attributes = kwargs #{k: v for k,v in kwargs.items()} # if k.contains('uuid')} 

        tracer=tracers[0]
        with tracer.start_as_current_span(span_name) as aspan:
          if inspect.isclass(wrapped):
            # class or classmethod
            aspan.set_attribute("xs.span.args.str", str(args))
            aspan.set_attribute("xs.span.kwargs.str", str(kwargs))
          else:
            # function, staticmethod or instancemethod
            for k,v in inspect.getcallargs(wrapped, *args, **kwargs).items():
              aspan.set_attribute("xs.span.arg." + k, str(v))
          result = wrapped(*args, **kwargs) #must be inside aspan to produce nested trace

        #TODO: clone aspan for each other tracer in remaining tracers
        #for tracer in tracers[1:]:
        #  tracer.add(aspan.clone())
        return result

    def autoinstrument_class(aclass):
      # auto-instrumentation of a class
      try:
        #print("aclass="+str(aclass))
        if inspect.isclass(aclass):
          tracer = tracers[0]
          my_module_name = str(aclass.__module__) + ":" + aclass.__qualname__
          #print("module_name="+my_module_name)
          with tracer.start_as_current_span("auto_instrumentation.add: " + my_module_name):
            for name in [fn for fn in aclass.__dict__ if callable(getattr(aclass, fn))]:
            #for name in func.__dict__:
              f = aclass.__dict__[name]
              span_name = "class.instrument:" + my_module_name + "." + name + "=" + str(f)
              with tracer.start_as_current_span(span_name):
                if name not in ["__getattr__", "__call__", "__init__"]: #avoids python error 'maximum recursion depth exceeded in comparison' in XenAPI
                  #and name not in ["__repr__"]): #avoids infinite recursion in blktap2
                  #print(str(aclass)+"->"+name)
                  try:
                    setattr(aclass, name, wrapper(f))
                  except Exception as e:
                    debug("setattr.Wrapper: Exception " + traceback.format_exc())
      except Exception as e:
        debug("Wrapper: Exception " + traceback.format_exc())

    def autoinstrument_module(amodule):
      classes = inspect.getmembers(amodule, inspect.isclass)
      for (class_name, aclass) in classes:
        if class_name not in []: #["Failure", "Session", "UDSHTTPConnection", "_Dispatcher"]:
          #print("class="+class_name+":"+str(aclass))
          autoinstrument_class(aclass)
      functions = inspect.getmembers(amodule, inspect.isfunction)
      for (function_name, afunction) in functions:
        #print("function="+function_name+":"+str(afunction))
        setattr(amodule, function_name, wrapper(afunction)) 

    #print("wrapped="+str(wrapped))
    if inspect.ismodule(wrapped):
      #print("ismodule=%s" % wrapped)
      autoinstrument_module(wrapped)

    #for m in list(sys.modules):
    #  print(str(m))

    return wrapper(wrapped)

  # @observer.span is now operational
  span = span_of_tracers

  def _patch_module(module_name):
    wrapt.importer.discover_post_import_hooks(module_name)
    wrapt.importer.when_imported(module_name)(lambda hook: span(wrapped=hook))

  # patch_module is now operational
  patch_module = _patch_module
  for m in module_names:
    patch_module(m)


#https://github.com/owais/opentelemetry-python/blob/6024755f71e77b787fc09a660adaf832f3f89173/opentelemetry-instrumentation/src/opentelemetry/instrumentation/auto_instrumentation/__init__.py

if __name__ == '__main__':
  # run a program passed as parameter, with its original arguments
  # so that there's no need to manually decorate the program.
  # The program will be forcibly instrumented by patch_module above when the corresponding module in program is imported.
  import runpy
  import sys

  # shift all the argvs one left
  sys.argv = sys.argv[1:]
  argv0=sys.argv[0]

  @span(span_name_prefix=argv0)
  def run(file):
    runpy.run_path(file, run_name='__main__')

  run(argv0)


