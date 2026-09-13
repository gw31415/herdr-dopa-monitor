#!/usr/bin/env python3
"""Unit tests for the pure monitor logic: state machine, transition side
effects (owned dopa child), and state file I/O. No real dopa or herdr calls."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import monitor  # noqa: E402

SG = 5.0
STG = 30.0


class AnyAgentWorkingTests(unittest.TestCase):
    def test_empty(self):
        self.assertFalse(monitor.any_agent_working([]))

    def test_no_working(self):
        self.assertFalse(monitor.any_agent_working(["idle", "done", "blocked", "unknown"]))

    def test_working_present(self):
        self.assertTrue(monitor.any_agent_working(["idle", "working"]))

    def test_case_sensitive(self):
        self.assertFalse(monitor.any_agent_working(["Working"]))


class NextStateTests(unittest.TestCase):
    def test_off_idle_stays(self):
        self.assertEqual(monitor.next_monitor_state("off", False, 99, SG, STG), "off")

    def test_off_working_arms(self):
        self.assertEqual(monitor.next_monitor_state("off", True, 0, SG, STG), "pending_on")

    def test_pending_on_cancel(self):
        self.assertEqual(monitor.next_monitor_state("pending_on", False, 1, SG, STG), "off")

    def test_pending_on_hold(self):
        self.assertEqual(
            monitor.next_monitor_state("pending_on", True, SG - 1, SG, STG), "pending_on")

    def test_pending_on_fire(self):
        self.assertEqual(
            monitor.next_monitor_state("pending_on", True, SG, SG, STG), "on")

    def test_on_hold(self):
        self.assertEqual(monitor.next_monitor_state("on", True, 99, SG, STG), "on")

    def test_on_cooldown(self):
        self.assertEqual(monitor.next_monitor_state("on", False, 0, SG, STG), "pending_off")

    def test_pending_off_resume(self):
        self.assertEqual(
            monitor.next_monitor_state("pending_off", True, 1, SG, STG), "on")

    def test_pending_off_hold(self):
        self.assertEqual(
            monitor.next_monitor_state("pending_off", False, STG - 1, SG, STG),
            "pending_off")

    def test_pending_off_fire(self):
        self.assertEqual(
            monitor.next_monitor_state("pending_off", False, STG, SG, STG), "off")

    def test_unknown_state_falls_off(self):
        self.assertEqual(monitor.next_monitor_state("bogus", True, 0, SG, STG), "off")


class FakeProc:
    def __init__(self, pid):
        self.pid = pid


def make_fns(alive_pids, spawn_pid=4242, spawn_raises=None, terminate_ok=True):
    logs = []

    def spawn_fn():
        if spawn_raises is not None:
            raise spawn_raises
        alive_pids.add(spawn_pid)
        return FakeProc(spawn_pid)

    def terminate_fn(pid):
        alive_pids.discard(pid)
        return terminate_ok

    def is_alive_fn(pid):
        return pid in alive_pids

    return spawn_fn, terminate_fn, is_alive_fn, logs.append


class HandleTransitionTests(unittest.TestCase):
    def test_enter_on_spawns(self):
        spawn, term, alive, log = make_fns(set())
        pid, ok = monitor.handle_transition("pending_on", "on", None, spawn, term, alive, log)
        self.assertTrue(ok)
        self.assertEqual(pid, 4242)

    def test_enter_on_adopts_live_pid(self):
        # live pid must be kept without spawning (boom fails the test if called)
        def boom():
            raise AssertionError("must not spawn when pid is alive")

        spawn, term, alive, log = make_fns({111})
        pid, ok = monitor.handle_transition("pending_on", "on", 111, boom, term, alive, log)
        self.assertTrue(ok)
        self.assertEqual(pid, 111)

    def test_enter_on_spawn_failure_is_error(self):
        spawn, term, alive, log = make_fns(set(), spawn_raises=RuntimeError("nope"))
        pid, ok = monitor.handle_transition("pending_on", "on", None, spawn, term, alive, log)
        self.assertFalse(ok)
        self.assertIsNone(pid)

    def test_resume_keeps_live_child(self):
        def boom():
            raise AssertionError("resume must not spawn")

        spawn, term, alive, log = make_fns({111})
        pid, ok = monitor.handle_transition("pending_off", "on", 111, boom, term, alive, log)
        self.assertTrue(ok)
        self.assertEqual(pid, 111)

    def test_resume_respawns_dead_child(self):
        spawn, term, alive, log = make_fns(set())
        pid, ok = monitor.handle_transition("pending_off", "on", 999, spawn, term, alive, log)
        self.assertTrue(ok)
        self.assertEqual(pid, 4242)

    def test_enter_off_terminates_child(self):
        spawn, term, alive, log = make_fns({111})
        calls = []

        def rec(pid):
            calls.append(pid)
            return term(pid)

        pid, ok = monitor.handle_transition("pending_off", "off", 111, spawn, rec, alive, log)
        self.assertTrue(ok)
        self.assertIsNone(pid)
        self.assertEqual(calls, [111])

    def test_enter_off_without_child(self):
        spawn, term, alive, log = make_fns(set())
        pid, ok = monitor.handle_transition("pending_off", "off", None, spawn, term, alive, log)
        self.assertTrue(ok)
        self.assertIsNone(pid)

    def test_pending_transitions_touch_nothing(self):
        calls = []

        def spawn():
            calls.append("spawn")
            return FakeProc(1)

        def term(pid):
            calls.append("term")
            return True

        pid, ok = monitor.handle_transition("off", "pending_on", None, spawn, term,
                                            lambda p: False, lambda m: None)
        self.assertTrue(ok)
        self.assertIsNone(pid)
        pid, ok = monitor.handle_transition("on", "pending_off", 111, spawn, term,
                                            lambda p: True, lambda m: None)
        self.assertTrue(ok)
        self.assertEqual(pid, 111)
        self.assertEqual(calls, [])


def make_cfg(state_path, **over):
    kw = dict(herdr_bin="herdr", poll_seconds=5.0, start_grace=SG, stop_grace=STG,
              state_path=state_path, dopa_bin="/tmp/dopa", armed=True)
    kw.update(over)
    return monitor.Config(**kw)


class IterateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state.json"

    def tearDown(self):
        self.tmp.cleanup()

    def run_iterate(self, ctx, statuses, now=1000.0, **cfg_over):
        cfg = make_cfg(self.state, **cfg_over)
        with mock.patch.object(monitor, "get_agent_statuses", return_value=statuses), \
             mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=False):
            return monitor.iterate(cfg, ctx, now)

    def test_idle_stays_off(self):
        ctx = monitor.MonitorCtx()
        out = self.run_iterate(ctx, ["idle"])
        self.assertEqual(out.monitor_state, "off")
        self.assertIsNone(out.dopa_pid)

    def test_working_arms_pending(self):
        ctx = monitor.MonitorCtx()
        out = self.run_iterate(ctx, ["working"])
        self.assertEqual(out.monitor_state, "pending_on")

    def test_pending_to_on_spawns(self):
        ctx = monitor.MonitorCtx(monitor_state="pending_on", last_transition=900.0)
        with mock.patch.object(monitor, "get_agent_statuses", return_value=["working"]), \
             mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=False), \
             mock.patch.object(monitor.dopa_ctl, "spawn_session",
                               return_value=FakeProc(4242)) as sp:
            out = monitor.iterate(make_cfg(self.state), ctx, 1000.0)
        sp.assert_called_once()
        self.assertEqual(out.monitor_state, "on")
        self.assertEqual(out.dopa_pid, 4242)

    def test_on_to_off_terminates(self):
        ctx = monitor.MonitorCtx(monitor_state="pending_off", dopa_pid=111,
                                 last_transition=900.0)
        with mock.patch.object(monitor, "get_agent_statuses", return_value=["idle"]), \
             mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "terminate_session",
                               return_value=True) as tm:
            out = monitor.iterate(make_cfg(self.state), ctx, 1000.0)
        tm.assert_called_once_with(111)
        self.assertEqual(out.monitor_state, "off")
        self.assertIsNone(out.dopa_pid)

    def test_disarmed_kills_child(self):
        ctx = monitor.MonitorCtx(monitor_state="on", dopa_pid=111)
        with mock.patch.object(monitor, "get_agent_statuses", return_value=["working"]), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "terminate_session",
                               return_value=True) as tm:
            out = monitor.iterate(make_cfg(self.state, armed=False), ctx, 1000.0)
        tm.assert_called_once_with(111)
        self.assertEqual(out.monitor_state, "off")
        self.assertIsNone(out.dopa_pid)

    def test_missing_dopa_is_error(self):
        ctx = monitor.MonitorCtx()
        with mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=False):
            out = monitor.iterate(make_cfg(self.state), ctx, 1000.0)
        self.assertEqual(out.monitor_state, "error")
        self.assertIsNotNone(out.last_error)

    def test_on_reconciles_dead_child(self):
        ctx = monitor.MonitorCtx(monitor_state="on", dopa_pid=111, last_transition=999.0)
        with mock.patch.object(monitor, "get_agent_statuses", return_value=["working"]), \
             mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=False), \
             mock.patch.object(monitor.dopa_ctl, "spawn_session",
                               return_value=FakeProc(4243)):
            out = monitor.iterate(make_cfg(self.state), ctx, 1000.0)
        self.assertEqual(out.monitor_state, "on")
        self.assertEqual(out.dopa_pid, 4243)

    def test_herdr_down_treated_as_idle(self):
        ctx = monitor.MonitorCtx(monitor_state="on", dopa_pid=111, last_transition=900.0)
        with mock.patch.object(monitor, "get_agent_statuses",
                               side_effect=monitor.HerdrError("down")), \
             mock.patch.object(monitor.dopa_ctl, "is_dopa_available", return_value=True), \
             mock.patch.object(monitor.dopa_ctl, "is_pid_alive", return_value=True):
            out = monitor.iterate(make_cfg(self.state), ctx, 1000.0)
        # working unknown -> treated idle -> pending_off, child kept
        self.assertEqual(out.monitor_state, "pending_off")
        self.assertEqual(out.dopa_pid, 111)


class StateFileTests(unittest.TestCase):
    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "state.json"
            ctx = monitor.MonitorCtx(monitor_state="on", dopa_pid=4242,
                                     last_transition=123.0, last_agent_working=True,
                                     agent_count=2)
            monitor.save_ctx(path, ctx)
            back = monitor.load_ctx(path)
            self.assertEqual(back.monitor_state, "on")
            self.assertEqual(back.dopa_pid, 4242)
            self.assertEqual(back.agent_count, 2)

    def test_corrupt_gives_defaults(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "state.json"
            path.write_text("{not json")
            ctx = monitor.load_ctx(path)
            self.assertEqual(ctx.monitor_state, "off")
            self.assertIsNone(ctx.dopa_pid)


if __name__ == "__main__":
    unittest.main()
