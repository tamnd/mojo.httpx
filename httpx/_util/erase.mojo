"""Holding a value whose type has been forgotten.

Mojo 1.0 has no trait objects. A struct field has one type, decided when the
struct is compiled, so a `Client` cannot simply hold "some transport" the way a
Python or Rust one would. Everything pluggable in this library runs into that
wall: transports, auth schemes and event hooks are all chosen by the user at
runtime, and all of them have to live in a field or a list.

The way through is a hand rolled vtable. A capture free function has a concrete
type, spelled with `thin`, and those are storable. So a pluggable interface
becomes a struct holding one of these boxes plus a thin function pointer per
method, and the functions are generated per concrete type by a generic shim.
`ErasedBox` is the state half of that: a heap allocation holding the value, a
reference count, and the one function that knows how to destroy it, which is
the only thing here that still remembers what the type was.

This is the single place in the library outside `_ffi` and `_io` that touches a
raw pointer, and the lint has a named exemption for the file rather than a
general one for the layer. Keeping it to one small file is the point: the
unsafety is the price of the extension point, and it is worth paying once.

Copies are explicit. Mojo 1.0 does not call a user written copy hook for an
implicit copy, so a box that claimed to be implicitly copyable would hand out
copies that never incremented the count and then free the value while other
copies still pointed at it. `copy` is a method, and callers write it out.
"""

comptime Ptr[T: AnyType] = Pointer[T, MutUntrackedOrigin]
"""A pointer whose lifetime is managed by hand, which is what this file does.

Untracked rather than tracked because there is nothing for the compiler to
track the value against. The whole purpose is an allocation that outlives every
scope that can name its type.
"""


struct ErasedBox(Movable):
    """A reference counted heap value that no longer knows its own type."""

    var _value: Int
    """The address of the value.

    An address rather than a `Pointer` because a pointer needs a pointee type
    and forgetting the pointee type is the entire job. Storing the number keeps
    the unsafe cast at the two places that do the remembering.
    """

    var _refs: Int
    """The address of the reference count.

    Beside the value rather than inside it, because the value is a user type
    that knows nothing about being shared. Not atomic: this library is single
    threaded today, and an atomic count would suggest a thread safety that
    nothing else here provides.
    """

    var _drop: def(Int) thin -> None
    """Destroy the value and free it, from a shim that still knows the type.

    The only surviving trace of what was boxed. Without it the allocation could
    be freed but the value inside it would never be destroyed, which for a
    transport means every socket it holds is leaked.
    """

    def __init__(out self, value: Int, refs: Int, drop: def(Int) thin -> None):
        self._value = value
        self._refs = refs
        self._drop = drop

    @staticmethod
    def make[T: Movable & Deinitable](var value: T) -> Self:
        """Move `value` onto the heap and forget what it was."""

        def _drop(address: Int) -> None:
            # Sound because the address can only have come from `make[T]` for
            # this same `T`. `AnyTransport` and its relatives are the only
            # things that build a box, they build it and the trampolines from
            # one type parameter, and nothing hands out the address.
            var p = Ptr[T](unsafe_from_address=address)
            p.unsafe_deinit_pointee()
            p.unsafe_free()

        return Self(_leak[T](value^), _leak[Int](1), _drop)

    def copy(self) -> Self:
        """Another reference to the same value.

        Shared rather than duplicated on purpose. Two clients built from one
        transport should queue on the same connection pool, and a pool that was
        copied along with the handle would quietly double the connection limit.
        """
        Ptr[Int](unsafe_from_address=self._refs)[] += 1
        return Self(self._value, self._refs, self._drop)

    def __deinit__(deinit self):
        # Both addresses were allocated in `make` and are only ever shared with
        # copies of this box, each of which counted itself in on the way in and
        # is counting itself out here. Reaching zero therefore means this is the
        # last handle, so nothing else can be pointing at either allocation.
        var refs = Ptr[Int](unsafe_from_address=self._refs)
        refs[] -= 1
        if refs[] == 0:
            self._drop(self._value)
            refs.unsafe_free()

    def get[T: AnyType](self) -> ref[MutAnyOrigin] T:
        """The boxed value, as the type it was made from.

        Mutable through an immutable box, which is deliberate and is the reason
        this is confined to one file. The box is a handle to shared state, like
        a file descriptor, so `mut` on the handle would say something about the
        handle that is not true of what it points at.

        Sound only when `T` is the type the box was made with. Every caller is
        a trampoline generated from the same type parameter as the box, so
        nothing outside this pattern can get the type wrong.
        """
        return Ptr[T](unsafe_from_address=self._value)[]


def _leak[T: Movable & Deinitable](var value: T) -> Int:
    """Move one value onto the heap and hand back its address.

    Through a `List` because Mojo 1.0 has no bare allocation call. The list is
    asked for room for one, given the value, and then relieved of the
    allocation, so nothing is copied and the block is exactly one `T`.
    """
    var holder = List[T](capacity=1)
    holder.append(value^)
    var allocation = holder.unsafe_take_allocation()
    return Int(allocation^.unsafe_leak())
