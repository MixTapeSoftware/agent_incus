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

Large uploads show up in the same places: see [Upload warnings](#upload-warnings).

## Getting the check

A new egress container has it. One set up by an earlier bxn keeps its old proxy until `bxn egress refresh --all`, or the next `bxn -c` that uses it, rebuilds it. `bxn egress refresh` then moves each container to the new proxy, and open connections keep running. `bxn egress ls` and `bxn doctor` say when an egress container is out of date. If the rebuild fails, the old proxies keep serving, and the same command retries it.

## Upload warnings

The proxy can't see what a connection carries, but it can see how much. A large upload to an allowed host is how copying out a whole repository or a database dump would look, so bxn makes one stand out. This is an alarm for bulk uploads only, not a guard against leaks.

**What is measured.** For each host, the bytes a container sends through HTTPS tunnels (`CONNECT`) to that host, over the last hour, added up across all of its connections. When a host first goes over its limit, the proxy logs it once; it logs that host again only after an hour has passed.

**The defaults** are in [`egress/upload-limits.txt`](egress/upload-limits.txt): 250M for any host, and 2G for hosts whose normal job is taking large uploads (the coding agents' APIs, which get the whole conversation with every request; code hosts; and the container and package registries people push to). Nothing is off by default. The numbers are starting guesses, set high so normal work doesn't set them off; `bxn egress log <container> --uploads` shows what each host was sent, largest first, to tune them by (it counts connections once they close; `--since` for longer than the last hour).

**Changing them.** `bxn egress upload-limit <container>` lists a container's limits and where each comes from. `bxn egress upload-limit <container> <host> 5G` sets one for that container (`default` for any host, `off` for none, `clear` to drop it). For every container, put lines like `github.com 5G` in `~/.config/boxen/egress-upload-limits.txt`. For a host, the container's own setting wins, then your file, then the shipped one. A host's own line wins over a wildcard (`*.example.com`, subdomains only), and the longest wildcard over a shorter one. Unlike the baseline, the shipped file isn't approved first: a change to it in an update applies at the container's next `bxn egress refresh`, and `bxn egress ls` says when one is waiting. A change applies to new connections; open ones keep the old limits until they close.

**Warn or cut.** By default, going over a limit is only logged. `bxn egress upload-cap <container> on` turns the cap on: under `enforce`, a write that would take a host over its limit closes that connection instead, and so does every write to that host until enough of the hour's bytes have aged out. Under `report` or `off` it still only warns. A cut connection gets no message; the tool sees it close. So the warning is how you find out:

- `bxn egress log <container>` lists large uploads under **WARNINGS**: the host, how much it was sent in the hour, its limit, whether it was cut, and how to raise that host's limit if the upload was yours.
- `bxn egress ls` puts a warning on the container's line, and the Network tab in the status view lists them first, as `large-upload`, or `upload-cut` when the cap cut it.
- The note in the agents' instructions tells an agent whose big push fails partway to tell you and point you to the log.

**What it doesn't catch.**

- **Small secrets.** A token or a key is a few dozen bytes. It passes any limit.
- **Slow uploads.** Anything under the limit in every hour passes, so 200M an hour gets out 4.8G a day without a warning.
- **Spreading it out.** Each host has its own count, and a wildcard gives every name under it its own: sending to many hosts keeps each under its limit.
- **Plain HTTP.** Only HTTPS tunnels are counted. Plain HTTP requests (`HTTP_PROXY`) aren't.
- **A new proxy generation starts from zero.** Counts live in the proxy's memory. Any change to the container's policy (a host allowed, a mode or limit changed, a proxy update) starts a new generation with no count; older generations keep counting the connections they still serve, each on its own.
- **The cap needs `enforce`, and someone to turn it on.** It's off by default, so a warning comes after the data has gone.

## Limits

This is a best-effort defence against common ways around an allowlist, not a complete solution. No approach can prevent every exploit. How well it holds depends on what runs in the container and which hosts are allowed: each allowed host, and above all each wildcard and each shared front end, is a way out.
