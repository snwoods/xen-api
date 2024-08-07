import time

import XenAPI

session = XenAPI.xapi_local()
try:
    session.xenapi.login_with_password("root", "", "2.3", "My Widget v0.2")
    hosts = session.xenapi.host.get_all()
    overall_start = time.time()
    def pp_host_latency(index, host):
        host_start = time.time()
        session.xenapi.host.get_servertime(host)
        host_latency = time.time() - host_start
        return f"Host {index} latency: {host_latency}"
    host_latencies = [pp_host_latency(index, host) for index, host in enumerate(hosts, start=1)]
    overall_latency = time.time() - overall_start
    print(host_latencies)
    print(f"Total latency: {overall_latency}")
finally:
    session.xenapi.session.logout()
