import time

import XenAPI

session = XenAPI.xapi_local()
try:
    session.xenapi.login_with_password("root", "", "2.3", "My Widget v0.2")
    hosts = session.xenapi.host.get_all()
    start = time.time()
    for h in hosts:
        session.xenapi.host.get_servertime(h)
    latency = time.time() - start
    print(f"Total latency: {latency}")
finally:
    session.xenapi.session.logout()
