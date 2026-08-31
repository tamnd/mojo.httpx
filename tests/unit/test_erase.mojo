"""Tests for the type erased box.

The most dangerous code in the library. Everything else can be wrong and
produce a bad answer, and this can be wrong and produce a use after free, so
the cases here are about lifetime rather than about behaviour: that the value
is destroyed exactly once, that copies share it rather than duplicating it, and
that the last copy is the one that ends it.
"""

from std.testing import assert_equal, assert_true

from httpx._util.erase import ErasedBox


struct Counted(Movable):
    """A value that says how many of it were destroyed, through a shared count.

    The count lives outside the value because the value is what gets destroyed,
    so anything kept inside it goes with it.
    """

    var n: Int
    var drops: ErasedBox

    def __init__(out self, n: Int, var drops: ErasedBox):
        self.n = n
        self.drops = drops^

    def __deinit__(deinit self):
        self.drops.get[Int]() += 1

    def bump(mut self) -> Int:
        self.n += 1
        return self.n


def _counter() -> ErasedBox:
    return ErasedBox.make[Int](0)


def _drop(var box: ErasedBox):
    """End one handle's life here rather than wherever Mojo decides.

    A value lives until its last use, which in a test that asserts on
    destruction is the assertion itself. Handing the box to a function that
    keeps it is the way to say now.
    """
    pass


def test_a_boxed_value_can_be_read_back() raises:
    var box = ErasedBox.make[Int](41)
    assert_equal(box.get[Int](), 41)


def test_a_boxed_value_can_be_mutated_through_the_box() raises:
    # Mutable through an immutable box on purpose. The box is a handle to
    # shared state, so `mut` on the handle would be saying something about the
    # handle rather than about what it points at.
    var box = ErasedBox.make[Int](1)
    box.get[Int]() += 4
    assert_equal(box.get[Int](), 5)


def test_a_copy_sees_the_same_value() raises:
    var box = ErasedBox.make[Int](7)
    var other = box.copy()
    box.get[Int]() = 9
    assert_equal(other.get[Int](), 9)


def test_a_boxed_value_is_destroyed_once() raises:
    var drops = _counter()
    var box = ErasedBox.make[Counted](Counted(1, drops.copy()))
    assert_equal(drops.get[Int](), 0)
    _drop(box^)
    assert_equal(drops.get[Int](), 1)


def test_a_value_survives_until_the_last_copy_goes() raises:
    # The whole reason for the reference count. Two clients built from one
    # transport must not leave the second one holding a freed pool.
    var drops = _counter()
    var box = ErasedBox.make[Counted](Counted(1, drops.copy()))
    var second = box.copy()
    _drop(box^)
    assert_equal(drops.get[Int](), 0)
    assert_equal(second.get[Counted]().bump(), 2)
    _drop(second^)
    assert_equal(drops.get[Int](), 1)


def test_a_copy_of_a_copy_still_counts() raises:
    var drops = _counter()
    var first = ErasedBox.make[Counted](Counted(1, drops.copy()))
    var second = first.copy()
    var third = second.copy()
    _drop(first^)
    _drop(second^)
    assert_equal(drops.get[Int](), 0)
    _drop(third^)
    assert_equal(drops.get[Int](), 1)


def test_boxes_of_the_same_type_are_separate() raises:
    var one = ErasedBox.make[Int](1)
    var two = ErasedBox.make[Int](2)
    one.get[Int]() = 100
    assert_equal(two.get[Int](), 2)


def test_a_boxed_value_can_be_moved_without_being_destroyed() raises:
    var drops = _counter()
    var box = ErasedBox.make[Counted](Counted(5, drops.copy()))
    var moved = box^
    assert_equal(drops.get[Int](), 0)
    assert_equal(moved.get[Counted]().n, 5)
    _drop(moved^)
    assert_equal(drops.get[Int](), 1)


def test_boxes_survive_a_list() raises:
    # Heterogeneous collections are most of what erasure is for, and a list
    # moves its elements around as it grows.
    var drops = _counter()
    var boxes = List[ErasedBox]()
    for i in range(4):
        boxes.append(ErasedBox.make[Counted](Counted(i, drops.copy())))
    assert_equal(boxes[2].get[Counted]().n, 2)
    boxes.clear()
    assert_equal(drops.get[Int](), 4)
