"""Public _asyncio accelerator surface backed by native assembly types."""

from _asyncio_native import (
    Future,
    Task,
    _current_tasks,
    _eager_tasks,
    _enter_task,
    _get_running_loop,
    _get_scheduled_tasks,
    _leave_task,
    _register_eager_task,
    _register_task,
    _set_running_loop,
    _swap_current_task,
    _unregister_eager_task,
    _unregister_task,
    current_task,
    get_event_loop,
    get_running_loop,
)

_scheduled_tasks = _get_scheduled_tasks()

__all__ = (
    "Future",
    "Task",
    "_current_tasks",
    "_eager_tasks",
    "_enter_task",
    "_get_running_loop",
    "_leave_task",
    "_register_eager_task",
    "_register_task",
    "_scheduled_tasks",
    "_set_running_loop",
    "_swap_current_task",
    "_unregister_eager_task",
    "_unregister_task",
    "current_task",
    "get_event_loop",
    "get_running_loop",
)
