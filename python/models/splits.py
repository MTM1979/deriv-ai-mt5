"""Time-ordered splits with purge and embargo.

Labels look ``horizon_bars`` into the future, so a training row near the
end of a train window can observe prices that belong to the test window.
The splitter therefore removes ``max(horizon, embargo)`` rows between
train and test.  Every window is expressed in bar indices on a single,
time-ordered series.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator

__all__ = [
    "Window",
    "purged_walk_forward",
    "purged_kfold",
    "assert_disjoint",
]


@dataclass(frozen=True)
class Window:
    train_start: int
    train_end: int
    test_start: int
    test_end: int

    def __post_init__(self) -> None:
        if self.train_start < 0 or self.train_end < self.train_start:
            raise ValueError("invalid train range")
        if self.test_start < self.train_end or self.test_end <= self.test_start:
            raise ValueError("invalid test range")

    @property
    def train_size(self) -> int:
        return self.train_end - self.train_start

    @property
    def test_size(self) -> int:
        return self.test_end - self.test_start

    @property
    def purge(self) -> int:
        return self.test_start - self.train_end


def purged_walk_forward(
    count: int,
    train_size: int,
    test_size: int,
    *,
    horizon: int = 0,
    embargo: int = 0,
    step: int | None = None,
    expanding: bool = False,
) -> Iterator[Window]:
    """Yield rolling (or expanding) train/test windows.

    ``count`` is the number of usable rows.  ``horizon`` is the label
    look-ahead in bars; it is the minimum purge.  ``step`` defaults to
    ``test_size``, so windows do not overlap in the test period.
    """
    count = int(count)
    train_size = int(train_size)
    test_size = int(test_size)
    if count <= 0:
        raise ValueError("count must be positive")
    if train_size < 1 or test_size < 1:
        raise ValueError("train_size and test_size must be positive")
    purge = max(0, int(horizon), int(embargo))
    step = int(step) if step is not None else test_size
    if step < 1:
        raise ValueError("step must be >= 1")

    cursor = 0
    while True:
        train_start = 0 if expanding else cursor
        train_end = cursor + train_size
        test_start = train_end + purge
        test_end = test_start + test_size
        if test_end > count:
            break
        yield Window(train_start, train_end, test_start, test_end)
        cursor += step


def purged_kfold(count: int, folds: int, *, horizon: int = 0) -> list[tuple[Window, int]]:
    """Purged K-fold: each fold is a test block, the rest is train.

    Returns ``(window, fold_index)`` pairs.  ``window.train_*`` still
    describes one contiguous range; callers that need the union of the
    remaining blocks should build the index list from the fold bounds.
    """
    count = int(count)
    folds = int(folds)
    if folds < 2:
        raise ValueError("folds must be >= 2")
    if count < folds:
        raise ValueError("count must be >= folds")
    block = count // folds
    if block < 1:
        raise ValueError("fold block is empty")
    purge = max(0, int(horizon))
    out: list[tuple[Window, int]] = []
    for k in range(folds):
        test_start = k * block
        test_end = count if k == folds - 1 else (k + 1) * block
        # A single contiguous train window cannot represent the union of
        # both sides of the test block; expose the left side and let the
        # caller add the right side.
        train_end = max(0, test_start - purge)
        if train_end <= 0:
            continue
        out.append((Window(0, train_end, test_start, test_end), k))
    return out


def assert_disjoint(window: Window) -> None:
    if window.test_start < window.train_end:
        raise AssertionError("train and test overlap")
