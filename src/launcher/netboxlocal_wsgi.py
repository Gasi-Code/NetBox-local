"""WSGI entry point for the bundled NetBoxLocal instance.

NetBox is normally deployed behind nginx, which serves everything under
STATIC_URL directly from disk. Django itself only serves static files when
DEBUG is True, so a bundle that runs waitress alone renders without any CSS or
JavaScript and NetBox shows its "Static Media Failure" page.

There is no web server to put in front of a single-user offline instance, so
WhiteNoise is wrapped around the NetBox application to serve STATIC_ROOT from
inside the WSGI stack. NetBox itself stays unpatched.
"""

from django.conf import settings
from netbox.wsgi import application as _netbox_application
from whitenoise import WhiteNoise

application = WhiteNoise(
    _netbox_application,
    root=str(settings.STATIC_ROOT),
    prefix=settings.STATIC_URL,
    # The bundle is immutable between installs and every request is loopback,
    # so aggressive caching costs nothing and keeps page loads snappy.
    max_age=31536000,
)
