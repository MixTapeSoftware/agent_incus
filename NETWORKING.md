# Networking

How bxn limits what a container can reach, what that stops and what it doesn't, and how to watch for trouble. The commands are in the README, under [Network Isolation](README.md#network-isolation) and [Egress Allowlist](README.md#egress-allowlist). This is a best-effort defence; see [Limits](#limits).

## What it does

- **Network isolation.** Containers on `boxenbr0` can't reach each other, services on the host, or private and LAN addresses. The internet stays open.
- **The egress allowlist.** An allowlisted container can reach only its own proxy, in an egress container. The proxy connects it only to the hosts on its list, on ports 80 and 443. The container can't look names up itself; the proxy does it.

## What the proxy sees

The proxy never decrypts anything. For each connection it sees:

- the hostname the container asks for, which it checks against the list;
- for HTTPS, the server name in the TLS handshake, which the client sends in the clear.

It doesn't see the URLs, headers or bodies of HTTPS requests. Plain HTTP requests pass through it whole, but it doesn't log their URLs, headers or bodies.

## Tunnels used for another name

An HTTPS connection through the proxy is a tunnel. The container asks for a host, the proxy checks it and connects, and then it passes bytes both ways. The proxy used to look only at the name the container asked for. What went through the tunnel was up to the container.

Many sites share a front end: one set of servers answers for thousands of names, and picks the site by the server name in the TLS handshake. So a container could ask the proxy for an allowed name, then start a TLS handshake inside the tunnel for a different name served by the same front end. The proxy would allow the tunnel, and the front end would serve a site that isn't on the list. That can happen whenever an allowed host shares a front end with hosts that aren't allowed, which is common behind large content delivery networks and cloud load balancers.

bxn now closes that gap. The first bytes in each tunnel must be a TLS handshake whose server name is the host the container asked for (letter case and a trailing dot aside). The proxy holds them back until it has read the name, so nothing reaches the destination before the check. It refuses a tunnel that:

- names a different host;
- names no host;
- doesn't start with TLS (another protocol, or plain HTTP inside a tunnel);
- starts with a handshake that's malformed or longer than TLS allows.

Under `enforce`, the tunnel is closed and the attempt logged. Under `report`, it's logged and let through. `off` doesn't check.

Legitimate tools connect to the host they asked the proxy for, so the check shouldn't get in the way of normal work. Plain HTTP goes to the proxy as ordinary requests (`HTTP_PROXY`), not through a tunnel. A client that encrypts its whole handshake (Encrypted Client Hello) shows its front end's public name instead of the host, so its tunnels are closed too.

## What remains

The check closes one common gap. Others stay open:

- **The name inside the encrypted request.** After a handshake for an allowed host, the HTTP request inside it names a host too, and the proxy can't see that one. Some shared front ends route on it and accept one that differs from the handshake's. Through such a front end, a container can still reach sites that aren't allowed.
- **Hosts that serve many accounts.** Code hosts, package registries, storage and paste services accept data from anyone with an account. A container that can reach one can send data to an account that isn't yours. Hosts in the baseline that take uploads from anyone with an account are marked `upload:` in [`egress/baseline.txt`](egress/baseline.txt).
- **Small secrets fit in any request.** A token is a few dozen characters. It fits in a URL, a header, or a subdomain under an allowed wildcard.
- **Anything sent to an allowed host.** The allowlist decides where connections go, not what they carry.

## Watching for trouble

- `bxn egress log <container>` lists what the container tried to reach in the last hour (`--since` for longer). When a tunnel was used for another name, a **WARNINGS** section comes first: the allowed host, how often, and what the handshake named.
- `bxn egress ls` puts a warning on the container's line when that happened in the last hour.
- In the status view (`bxn`), the Network tab lists them first, as `name-mismatch`.

A warning means something in the container tried to reach a host it isn't allowed, by going through one it is. Look at what runs in the container and what the agent was asked to do.

## Getting the check

A new egress container has it. One set up by an earlier bxn keeps its old proxy until `bxn egress refresh --all`, or the next `bxn -c` that uses it, rebuilds it. `bxn egress refresh` then moves each container to the new proxy, and open connections keep running. `bxn egress ls` and `bxn doctor` say when an egress container is out of date. If the rebuild fails, the old proxies keep serving, and the same command retries it.

## Upload warnings

Warnings for data sent to hosts that accept uploads from anyone are coming in a follow-up.

## Limits

This is a best-effort defence against common ways around an allowlist, not a complete solution. No approach can prevent every exploit. How well it holds depends on what runs in the container and which hosts are allowed: each allowed host, and above all each wildcard and each shared front end, is a way out.
