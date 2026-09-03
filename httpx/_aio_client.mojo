"""The async client, which is the ordinary client with the async transport in it.

There is no second implementation here. `AsyncClient` is `BaseClient` with
`AnyAsyncTransport` as its handle, so every behaviour a user knows from `Client`
is the same code and not a copy of it: the same header merge, the same base URL
resolution, the same cookie jar, the same event hooks, the same redirect chain
and the same auth loop. `httpx._client` explains why that was worth arranging.

## What is different, and it is less than it sounds

The requests go out through `httpx._pool.aio_pool`, so a request waiting on a
socket does not hold a runtime worker. On its own that buys nothing, because a
client sending one request at a time waits for it either way. What it buys is
`gather`, below, which is the only reason any of this exists.

## Why `gather` is a function taking a list

In httpx it is `asyncio.gather(client.get(a), client.get(b))`: the caller builds
the coroutines and combines them, and the client knows nothing about it. That
cannot work here. A coroutine that suspends inside a loop, which every real
request does, can only be handed to `_run` or to `TaskGroup.create_task`, and a
`Coroutine` is a linear type, so it cannot be stored in a variable, put in a
list or returned. There is no way to hand a caller a request in progress.

So the requests are handed over as data and the library does the combining. It
is narrower than `asyncio.gather`, which will wait on anything at all, and it
covers what `gather` is nearly always used for. It is a free function rather
than a method because that is what it is in httpx, and because it belongs to
the async client alone while every method on `BaseClient` belongs to both.

`stream` works, and the body comes out through `aiter_bytes`, `aiter_text`,
`aiter_lines` and `aiter_raw`, which are the same calls as the ones without the
`a`. `httpx._models.response` says why that is the honest answer rather than a
shortcut.

The one thing the async client will not do is an `https://` URL, which raises,
because there is no async TLS handshake and sending in the clear because the
secure path is unfinished is not a thing this library will do.
"""

from httpx._auth import AnyAuth
from httpx._client import BaseClient
from httpx._config import Timeout
from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.clock import unix_now
from httpx._io.deadline import now_ns
from httpx._models.cookies import Cookies
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.limits import Limits
from httpx._redirects import build_redirect_request
from httpx._stream.config import TlsConfig
from httpx._transport.aio_base import AnyAsyncTransport, erase_async_transport
from httpx._transport.aio_http import AsyncHTTPTransport


def _default_async_transport(
    var limits: Limits, var tls: TlsConfig
) raises -> AnyAsyncTransport:
    """The pool an async client gets when the caller named no transport.

    `tls` is dropped. Everything in it describes a handshake, and the async pool
    refuses an `https://` request before it would get as far as one, so there is
    nothing here for it to configure yet. It stays in the signature because the
    signature is shared with the synchronous client, and because this is where
    it starts being used the day the handshake exists.
    """
    return erase_async_transport(AsyncHTTPTransport(limits^))


comptime AsyncClient = BaseClient[AnyAsyncTransport, _default_async_transport]
"""The async client. See `BaseClient` for everything it can do."""


struct _Slot(Movable):
    """Where one request in a batch has got to.

    A batch is not a list of requests and a list of responses, because a
    request that was redirected is a request again. Each slot is a small state
    machine: something to send, or an answer, and the history and auth scheme
    that go with whichever it is.
    """

    var pending: Optional[Request]
    """What goes out in the next round, if this slot is not finished."""

    var answer: Optional[Response]
    """The answer, once nothing further is going to be sent for this slot."""

    var prior: Optional[Response]
    """The chain so far, waiting to be attached to whatever comes back next."""

    var scheme: Optional[AnyAuth]
    """This slot's own copy, so a digest challenge answered for one request
    does not become an answer the others give as well."""

    var hops: Int
    """Redirects followed since the last thing that was not a redirect."""

    def __init__(out self, var pending: Request, var scheme: Optional[AnyAuth]):
        self.pending = Optional[Request](pending^)
        self.answer = None
        self.prior = None
        self.scheme = scheme^
        self.hops = 0


def gather(
    mut client: AsyncClient,
    var requests: List[Request],
    timeout: Optional[Timeout] = None,
    follow_redirects: Optional[Bool] = None,
    var auth: Optional[AnyAuth] = None,
) raises -> List[Response]:
    """Send all of `requests` at once and answer in the order they went in.

    ```mojo
    var pending = List[Request]()
    pending.append(client.build_request("GET", "/one"))
    pending.append(client.build_request("GET", "/two"))
    var answers = httpx.gather(client, pending^)
    ```

    Everything the client would do for one request it does for each of these:
    the event hooks run per send, the cookie jar is read and written, the
    default encoding is attached, a redirect chain is followed for anyone who
    asked, and an auth scheme gets its retry. What is different is that all of
    them happen at the same time.

    A round is one call into the transport. Slots that came back with a
    redirect to follow or a challenge to answer go out again in the next round,
    together, so a batch where one request redirects twice and the rest are
    done in one hop costs three rounds rather than three sequential requests.

    ## When one of them fails

    The first failure is raised and the rest of the answers are dropped, which
    is what `asyncio.gather` does unless it is told otherwise. Every request in
    the round still ran to the end before the raise, so nothing is left holding
    a connection. A variant that hands failures back alongside successes is
    worth having and is not written yet, because the pool underneath reports a
    batch as one outcome rather than as a list of them.

    ## The timeout is per round

    Fresh deadlines each round, for the reason each hop of a redirect chain
    gets its own on the synchronous side: a request has not become slow by
    being redirected. The whole batch shares a round, so the round is as slow
    as the slowest request in it, which is what asking for them together means.
    """
    if client.is_closed():
        raise Error("RuntimeError: the client is closed")
    var budget = timeout.value() if timeout else client.timeout
    var follow = (
        follow_redirects.value() if follow_redirects else client.follow_redirects
    )

    var slots = List[_Slot]()
    while len(requests) > 0:
        var scheme: Optional[AnyAuth] = None
        if auth:
            scheme = Optional[AnyAuth](auth.value().copy())
        elif client.auth:
            # A copy for each slot rather than the client's own, because
            # signing is a mutation on the scheme and every slot is about to do
            # it. The copy shares the state underneath, so a digest client that
            # has already been challenged stays challenged.
            scheme = Optional[AnyAuth](client.auth.value().copy())

        var first = requests.pop(0)
        if scheme:
            var signing = scheme.take()
            first = signing.sign(first^)
            scheme = Optional[AnyAuth](signing^)
        slots.append(_Slot(first^, scheme^))

    while True:
        var indices = List[Int]()
        var outgoing = List[Request]()
        for i in range(len(slots)):
            if not slots[i].pending:
                continue
            var going = slots[i].pending.take()
            # Indexed rather than `for ref`, which wants a copyable element and
            # a hook is not one.
            for h in range(len(client.event_hooks.request)):
                var passed = client.event_hooks.request[h].call(going^)
                going = passed^
            indices.append(i)
            outgoing.append(going^)
        if len(indices) == 0:
            break

        # One instant for the whole round, which is true: they did all start
        # together. Each response still reports its own round rather than the
        # whole batch, so a redirect chain shows up as several timings.
        var started = now_ns()
        var answers = client._transport.handle_many(
            outgoing^, budget.deadlines()
        )

        for k in range(len(indices)):
            var i = indices[k]
            var response = answers.pop(0)
            response.begin_timing(started)
            # Before anything reads the body, so a hook calling `text()` on a
            # response with no charset gets the client's answer.
            response.default_encoding = client.default_encoding.copy()
            _ = client.cookies.extract(
                response.request().url, response.headers, unix_now()
            )
            for h in range(len(client.event_hooks.response)):
                var passed = client.event_hooks.response[h].call(response^)
                response = passed^
            if slots[i].prior:
                response.inherit_history(slots[i].prior.take())
            _advance(client, slots, i, response^, follow)

    var out = List[Response]()
    while len(slots) > 0:
        var slot = slots.pop(0)
        out.append(slot.answer.take())
    return out^


def _advance(
    mut client: AsyncClient,
    mut slots: List[_Slot],
    index: Int,
    var response: Response,
    follow: Bool,
) raises:
    """Decide what happens to one slot now that its answer has arrived.

    Redirects first and auth after, which is the order the synchronous client
    uses and for the same reason: a challenge can come back from the end of a
    chain, and answering it means starting the chain again from the original
    URL. The other order would answer a challenge from an intermediate hop,
    which is a different server asking a different question.
    """
    if response.is_redirect():
        if follow and slots[index].hops >= client.max_redirects:
            raise new_error(
                ErrorKind.TOO_MANY_REDIRECTS,
                String("Exceeded maximum allowed redirects."),
            )
        var following = build_redirect_request(
            response.request(),
            response.status_code,
            response.headers["location"],
        )
        # The redirect builder strips `Cookie` on every hop, so this puts it
        # back, computed for where the request is now going.
        client._apply_cookies(following.url, Cookies(), following.headers)
        if follow:
            slots[index].hops += 1
            slots[index].prior = Optional[Response](response^)
            slots[index].pending = Optional[Request](following^)
            return
        # Not followed, so the caller gets the redirect itself with the next
        # request attached. The auth scheme still gets a look at it below,
        # because a 401 that also redirects is still a 401.
        response.set_next_request(following^)

    if slots[index].scheme:
        var answering = slots[index].scheme.take()
        if answering.requires_response_body():
            response.read()
        var retry = answering.next_request(response)
        slots[index].scheme = Optional[AnyAuth](answering^)
        if retry:
            # Back to the start of the chain, so the hop count starts again.
            slots[index].hops = 0
            slots[index].prior = Optional[Response](response^)
            slots[index].pending = Optional[Request](retry.take())
            return

    slots[index].answer = Optional[Response](response^)
