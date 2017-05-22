
import argparse
import json
import subprocess
import sys

from twisted.internet import reactor, protocol
from twisted.python import log
from twisted.web import http

try:
    # python 3+
    from urllib.parse import urljoin, urlparse
except ImportError:
    # python 2+
    from urlparse import urlparse, urljoin


class EventListenClient(http.HTTPClient):
    def __init__(self, host, port, method, uri, headers, body, event_handler):
        self.method = method
        self.uri = uri
        self.headers = headers
        self.post_data = body
        self.event_handler = event_handler
        self.host = host
        self.port = port

    def _send_request(self):
        log.msg("ProxyClient: sendRequest: %s %s" % (self.method, self.uri))
        self.sendCommand(self.method, self.uri)

    def _send_headers(self):
        if self.headers is not None:
            for key, value in self.headers.items():
                log.msg("ProxyClient: sendHeader: %s=%s" % (key, value))
                self.sendHeader(key.encode('UTF-8'), value.encode('UTF-8'))
        self.endHeaders()

    def _send_post_data(self):
        log.msg("ProxyClient: sendPostData: %s" % (self.post_data))
        if self.post_data is not None and len(self.post_data) > 0:
            self.transport.write(self.post_data)

    def _abort(self):
        log.msg("ProxyClient: aborting")
        self.transport.loseConnection()
        reactor.stop()

    def connectionMade(self):
        log.msg("ProxyClient: connectionMade")
        self.setHost(self.host.encode('UTF-8'), self.port)
        self._send_request()
        self._send_headers()
        self._send_post_data()

    def handleStatus(self, version, code, message):
        log.msg("ProxyClient: handleStatus: %s %s %s" % (version, code, message))
        if code != '200':
            self._abort()

    def handleHeader(self, key, value):
        log.msg("ProxyClient: handleHeader: %s=%s" % (key, value))

    def handleResponse(self, data):
        log.msg("ProxyClient: handleResponse: data=%s" % data)
        parsed_data = json.loads(data.decode('UTF-8'))
        for i in parsed_data:
            fixed_ip = i.get("fixed_ip_address", None)
            floating_ip = i.get("floating_ip_address", None)
            if fixed_ip is None or fixed_ip == '':
                self.event_handler.on_disassociate(floating_ip)
            else:
                self.event_handler.on_associate(floating_ip, fixed_ip)


class ProxyClientFactory(protocol.ClientFactory):
    protocol = EventListenClient

    def __init__(self, host, port, method, uri, headers, body, event_handler):
        self.method = method
        self.uri = uri
        self.headers = headers
        self.event_handler = event_handler
        self.body = body
        self.host = host
        self.port = port

    def buildProtocol(self, addr):
        log.msg("ProxyClientFactory: buildProtocol: method=%s, uri=%s, headers=%s"
                % (self.method, self.uri, self.headers))
        return self.protocol(self.host, self.port,
                             self.method, self.uri, self.headers, self.body, self.event_handler)

    def clientConnectionFailed(self, connector, reason):
        log.err("ProxyClientFactory: Server connection failed: %s" % reason)
        reactor.stop()


class EventHandler:
    def __init__(self, callbacks):
        self._callbacks = callbacks

    def on_disassociate(self, floating_ip):
        cb = self._callbacks.get('fip_disassociate', None)
        if cb is None:
            log.msg("EventHandler: on_disassociate: no callback")
            return
        self._call_callback([cb, floating_ip])

    def on_associate(self, floating_ip, fixed_ip):
        cb = self._callbacks.get('fip_associate', None)
        if cb is None:
            log.msg("EventHandler: on_associate: no callback")
            return
        self._call_callback([cb, floating_ip, fixed_ip])

    @staticmethod
    def _call_callback(args):
        log.msg('EventHandler: call callback: %s' % (args, ))
        subprocess.call(args)


def parse_opts():
    parser = argparse.ArgumentParser()
    parser.add_argument('--address', type=str,
                        default='127.0.0.1',
                        help='Contrail API address')
    parser.add_argument('--port', type=int,
                        default=8082,
                        help='Contrail API address')
    # parser.add_argument('--protocol', type=str,
    #                     default='http',
    #                     help='Protocol http/https')
    parser.add_argument('--headers', type=str,
                        default=None,
                        help='Custom HTTP headers in json format')
    parser.add_argument('--user_id', type=str,
                        help='User ID')
    parser.add_argument('--tenant_id', type=str,
                        help='Tenant ID')
    parser.add_argument('--fip_associate', type=str,
                        default=None,
                        help='FIP associate script callback')
    parser.add_argument('--fip_disassociate', type=str,
                        default=None,
                        help='FIP associate script callback')

    return parser.parse_args()


def main():
    options = parse_opts()
    log.startLogging(sys.stdout)
    headers = json.loads(options.headers) if options.headers is not None else None
    body = {
        "data": {
            "fields": [],
            "filters": {},
        },
        "context": {
            "user_id": options.user_id,
            "roles": [
                "_member_",
                "Admin",
            ],
            "tenant_id": options.tenant_id,
            "is_admin": True,
            "operation": "READALL",
            "type": "floatingip",
            "tenant": options.tenant_id,
        }
    }
    callbacks = {}
    if options.fip_associate is not None:
        callbacks['fip_associate'] = options.fip_associate
    if options.fip_disassociate is not None:
        callbacks['fip_disassociate'] = options.fip_disassociate
    client_factory = ProxyClientFactory(
        host=options.address,
        port=options.port,
        method='POST',
        uri='/neutron/floatingip',
        headers=headers,
        body=body,
        event_handler=EventHandler(callbacks))
    reactor.connectTCP(options.address, options.port, client_factory)
    reactor.run()


if __name__ == "__main__":
    main()