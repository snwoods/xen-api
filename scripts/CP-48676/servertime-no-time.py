import XenAPI

session = XenAPI.xapi_local()
try:
    session.xenapi.login_with_password("root", "", "2.3", "My Widget v0.2")
    hosts = session.xenapi.host.get_all()
    for h in hosts:
        session.xenapi.host.get_servertime(h)
finally:
    session.xenapi.session.logout()