
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
    def __init__(self, method, uri, headers, event_handler):
        self.method = method
        self.uri = uri
        self.headers = headers
        self.post_data = None
        self.event_handler = event_handler
        self.raw_data_buffer = ''

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
         log.msg("ProxyClient: handleResponse...")
         # finish processing of long polling request
         self._abort()

    def rawDataReceived(self, data):
        self.raw_data_buffer += data.decode('UTF-8')
        msg = self.raw_data_buffer.split('\n')
        while len(msg) > 2:
            event = msg[0].split(':', 1)
            if len(event) != 2 or event[0].strip() != 'event':
                msg = msg[1:]
                log.msg('ProxyClient: rawDataReceived: skip line: not event: %s' % event)
                continue
            if event[1].strip() != 'update':
                msg = msg[1:]
                log.msg('ProxyClient: rawDataReceived: skip event: event is not update: %s' % event)
                continue
            event_data = msg[1].split(':', 1)
            msg = msg[2:]
            if len(event_data) != 2 or event_data[0].strip() != 'data':
                log.msg('ProxyClient: rawDataReceived: skip event: no data: %s' % event_data)
                continue
            # log.msg('ProxyClient: rawDataReceived: process event: event_data=%s' % event_data)
            log.msg('ProxyClient: rawDataReceived: process event')
            event_data = json.loads(event_data[1].strip())
            self.event_handler.on_event(event_data)
        self.raw_data_buffer = '\n'.join(msg) if len(msg) > 0 else ''
        log.msg('ProxyClient: rawDataReceived: not all data received, waiting next chunk, raw_data_buffer=%s' % self.raw_data_buffer)


class ProxyClientFactory(protocol.ClientFactory):
    protocol = EventListenClient

    def __init__(self, method, uri, headers, event_handler):
        self.method = method
        self.uri = uri
        self.headers = headers
        self.event_handler = event_handler

    def buildProtocol(self, addr):
        log.msg("ProxyClientFactory: buildProtocol: method=%s, uri=%s, headers=%s"
                % (self.method, self.uri, self.headers))
        return self.protocol(self.method, self.uri, self.headers, self.event_handler)

    def clientConnectionFailed(self, connector, reason):
        log.err("ProxyClientFactory: Server connection failed: %s" % reason)
        reactor.stop()


class EventHandler:
    def __init__(self, callbacks):
        self._callbacks = callbacks

    def on_event(self, event_data):
        # TODO: rework to process asynchronously
        event_type = event_data.get('type', None)
        if event_type == 'UveVMInterfaceAgent':
            self.on_vm_interface(event_data)

    def on_vm_interface(self, event_data):
        event_value = event_data.get('value', None)
        if event_value is None:
            log.msg("EventHandler: on_vm_interface: No value in event data")
            return
        vm_uuid = event_value.get('vm_uuid', None)
        if vm_uuid is None:
            log.msg("EventHandler: on_vm_interface: No vm_uuid in event data")
            return
        floating_ips = event_value.get('floating_ips', None)

        if floating_ips is None or len(floating_ips) == 0:
            self._on_fip_disassociate(vm_uuid)
            return
        # TODO: only first IP is processed for now
        fip = floating_ips[0].get('ip_address', None)
        if fip is None:
            log.msg("EventHandler: on_vm_interface: No fip is empty")
            return
        self._on_fip_associate(vm_uuid, fip)

    def _on_fip_disassociate(self, vm_uuid):
        cb = self._callbacks.get('fip_disassociate', None)
        if cb is None:
            log.msg("EventHandler: _on_fip_disassociate: no callback")
            return
        self._call_callback([cb, vm_uuid])

    def _on_fip_associate(self, vm_uuid, fip):
        cb = self._callbacks.get('fip_associate', None)
        if cb is None:
            log.msg("EventHandler: _on_fip_associate: no callback")
            return
        self._call_callback([cb, vm_uuid, fip])

    @staticmethod
    def _call_callback(args):
        subprocess.call(args)


def parse_opts():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', type=str,
                        default='http://127.0.0.1:8081/analytics/uve-stream?tablefilt=virtual-machine-interface',
                        help='Url to get long polling updates')
    parser.add_argument('--headers', type=str,
                        default=None,
                        help='Custom HTTP headers in json format')
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

    parsed_url = urlparse(options.url)

    if ':' in parsed_url.netloc:
        host, port = parsed_url.netloc.split(':')
        port = int(port)
    else:
        host, port = parsed_url.netloc, 80

    if len(parsed_url.query) > 0:
        uri = parsed_url.path + '?' + parsed_url.query
    else:
        uri = parsed_url.path

    headers = json.loads(options.headers) if options.headers is not None else None

    callbacks = {}
    if options.fip_associate is not None:
        callbacks['fip_associate'] = options.fip_associate
    if options.fip_disassociate is not None:
        callbacks['fip_disassociate'] = options.fip_disassociate

    event_handler = EventHandler(callbacks)
    client_factory = ProxyClientFactory(method='GET', uri=uri, headers=headers, event_handler=event_handler)
    reactor.connectTCP(host, port, client_factory)
    reactor.run()


if __name__ == "__main__":
    main()