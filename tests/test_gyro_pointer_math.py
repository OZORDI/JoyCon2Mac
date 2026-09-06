import math
import unittest
from pathlib import Path


NOMINAL_PACKET_RATE = 200.0 / 3.0
FRESHNESS_SECONDS = 0.0455
MAX_PACKET_DT = 0.025
COUNTS_PER_DEGREE = {"slow": 80.0, "normal": 120.0, "fast": 160.0}
GESTURE_THRESHOLD = 60.0
GESTURE_KEY_DWELL_SECONDS = 0.040
CONTROL_ARROW_USAGES = {
    "right": 0x4F,
    "left": 0x50,
    "down": 0x51,
    "up": 0x52,
}
GYRO_REARM_SECONDS = 0.15
SURFACE_CONFIRM_FRAMES = 3
SCROLL_DEADZONE = 4000
MAX_SCROLL_CLICKS_PER_SECOND = 40.0 * (200.0 / 3.0) / 120.0


def optical_gesture_direction(x, y):
    if abs(x) < GESTURE_THRESHOLD and abs(y) < GESTURE_THRESHOLD:
        return None
    if abs(x) >= abs(y):
        return "left" if x < 0 else "right"
    return "up" if y < 0 else "down"


def extract_whole(value):
    return math.floor(value + 1e-9) if value >= 0 else math.ceil(value - 1e-9)


def regular_packet_times(seconds, rate=NOMINAL_PACKET_RATE):
    times = [0.0]
    interval = 1.0 / rate
    while times[-1] < seconds:
        times.append(min(seconds, times[-1] + interval))
    return times


def integrate_packet_rate(rate_degrees_per_second, timestamps, scale):
    fraction = 0.0
    emitted = 0
    previous = timestamps[0]
    for timestamp in timestamps[1:]:
        dt = timestamp - previous
        if dt <= 0:
            continue
        previous = timestamp
        if dt > FRESHNESS_SECONDS:
            fraction = 0.0
            continue
        dt = min(dt, MAX_PACKET_DT)
        fraction += rate_degrees_per_second * dt * scale
        whole = extract_whole(fraction)
        fraction -= whole
        emitted += whole
    return emitted, fraction


def integrate_rate(rate_degrees_per_second, seconds, scale):
    return integrate_packet_rate(
        rate_degrees_per_second,
        regular_packet_times(seconds),
        scale,
    )


def gyro_pointer_delta(pitch_rate, yaw_rate, seconds, scale):
    return yaw_rate * seconds * scale, -pitch_rate * seconds * scale


def gyro_right_stick(pitch_rate, yaw_rate, activation_rate,
                     full_rate, minimum_output, response_curve):
    x = yaw_rate
    y = -pitch_rate
    magnitude = math.hypot(x, y)
    if magnitude <= activation_rate:
        return 0.0, 0.0
    normalized = max(
        0.0,
        min(1.0, (magnitude - activation_rate) / (full_rate - activation_rate)),
    )
    output_magnitude = minimum_output + (
        1.0 - minimum_output
    ) * normalized ** response_curve
    return (
        x / magnitude * output_magnitude,
        y / magnitude * output_magnitude,
    )


def blend_right_stick(physical, gyro):
    x = physical[0] + gyro[0]
    y = physical[1] + gyro[1]
    magnitude = math.hypot(x, y)
    if magnitude > 1.0:
        x /= magnitude
        y /= magnitude
    return x, y


def normalize(vector):
    length = math.sqrt(sum(component * component for component in vector))
    if length < 0.0001:
        return None
    return tuple(component / length for component in vector)


def player_space_yaw(gyro_y, gyro_z, gravity):
    world_yaw = gyro_y * gravity[1] + gyro_z * gravity[2]
    relaxed = min(abs(world_yaw) * math.sqrt(2.0), math.hypot(gyro_y, gyro_z))
    return math.copysign(relaxed, world_yaw) if world_yaw else 0.0


def canonical_pointer_yaw(yaw, side):
    return -yaw if side == "right" else yaw


def raw_accel_player_space_yaw(gyro_y, gyro_z, accel):
    return player_space_yaw(gyro_y, gyro_z, normalize(accel))


def update_gravity(gravity, gyro, accel, dt):
    accel_magnitude = math.sqrt(sum(component * component for component in accel))
    accel_direction = normalize(accel)
    omega = tuple(component * math.pi / 180.0 for component in gyro)
    cross = (
        omega[1] * gravity[2] - omega[2] * gravity[1],
        omega[2] * gravity[0] - omega[0] * gravity[2],
        omega[0] * gravity[1] - omega[1] * gravity[0],
    )
    predicted = normalize(tuple(value - cross_value * dt for value, cross_value in zip(gravity, cross)))
    if accel_direction is None or abs(accel_magnitude - 1.0) >= 0.10:
        return predicted
    alignment = max(-1.0, min(1.0, sum(a * b for a, b in zip(predicted, accel_direction))))
    error_angle = math.acos(alignment)
    correction_limit = math.radians(10.0)
    if error_angle >= correction_limit:
        return predicted
    confidence = 1.0 - error_angle / correction_limit
    correction = max(0.0, min(1.0, dt * 4.0 * confidence))
    return normalize(
        tuple(value + (target - value) * correction for value, target in zip(predicted, accel_direction))
    )


def rate_at(previous_time, previous_rate, current_time, current_rate, target_time):
    if previous_time >= current_time or target_time >= current_time:
        return current_rate
    if target_time <= previous_time:
        return previous_rate
    amount = (target_time - previous_time) / (current_time - previous_time)
    return previous_rate + (current_rate - previous_rate) * amount


def rate_at_history(history, target_time):
    if target_time <= history[0][0]:
        return history[0][1]
    for previous, current in zip(history, history[1:]):
        if target_time <= current[0]:
            return rate_at(previous[0], previous[1], current[0], current[1], target_time)
    return history[-1][1]


def fused_rate(left, right):
    target = min(left[2], right[2])
    left_rate = rate_at(*left, target)
    right_rate = rate_at(*right, target)
    return (left_rate + right_rate) * 0.5


def clamp_cursor(position, delta, bounds):
    return tuple(
        max(0, min(limit, coordinate + movement))
        for coordinate, movement, limit in zip(position, delta, bounds)
    )


class GyroActivationModel:
    def __init__(self, mode="hold", slots=("zl", "none", "none")):
        self.mode = mode
        self.slots = slots
        self.master_enabled = False
        self.toggle_latched = False
        self.previously_pressed = set()

    def set_master_enabled(self, enabled):
        self.master_enabled = enabled
        if not enabled:
            self.toggle_latched = False

    def update(self, pressed_buttons):
        configured = {slot for slot in self.slots if slot != "none"}
        pressed = set(pressed_buttons) & configured
        rising = pressed - self.previously_pressed
        self.previously_pressed = pressed
        if self.mode == "toggle" and self.master_enabled and rising:
            self.toggle_latched = not self.toggle_latched

        if not self.master_enabled:
            return False
        if self.mode == "continuous":
            return True
        if self.mode == "hold":
            return bool(pressed)
        return self.toggle_latched


def integrate_gyro_scroll(stick_y, seconds):
    if abs(stick_y) <= SCROLL_DEADZONE:
        return 0
    intensity = (abs(stick_y) - SCROLL_DEADZONE) / (32767.0 - SCROLL_DEADZONE)
    accumulator = 0.0
    emitted = 0
    timestamps = regular_packet_times(seconds)
    for previous, timestamp in zip(timestamps, timestamps[1:]):
        dt = min(timestamp - previous, MAX_PACKET_DT)
        accumulator += math.copysign(
            intensity * MAX_SCROLL_CLICKS_PER_SECOND * dt,
            stick_y,
        )
        whole = extract_whole(accumulator)
        accumulator -= whole
        emitted += whole
    return emitted


class GyroPacketClock:
    def __init__(self, source="fused"):
        self.source = source
        self.clock_side = None
        self.last_emit = None

    def packet(self, timestamp, side, left_fresh, right_fresh):
        have_clock = False
        clock_side = side
        if self.source == "left":
            if left_fresh:
                clock_side = "left"
                have_clock = True
        elif self.source == "right":
            if right_fresh:
                clock_side = "right"
                have_clock = True
        else:
            if self.clock_side is not None:
                clock_fresh = left_fresh if self.clock_side == "left" else right_fresh
                if clock_fresh:
                    clock_side = self.clock_side
                    have_clock = True
            packet_fresh = left_fresh if side == "left" else right_fresh
            if not have_clock and packet_fresh:
                clock_side = side
                have_clock = True

        if not have_clock:
            self.clock_side = None
            self.last_emit = None
            return None

        changed = self.clock_side != clock_side
        self.clock_side = clock_side
        if side != clock_side:
            return None
        if changed or self.last_emit is None:
            self.last_emit = timestamp
            return None

        dt = timestamp - self.last_emit
        if dt <= 0:
            return None
        self.last_emit = timestamp
        if dt > FRESHNESS_SECONDS:
            return None
        return min(dt, MAX_PACKET_DT)


class SurfaceGate:
    def __init__(self):
        self.known = False
        self.on_surface = False
        self.surface_frames = 0
        self.air_frames = 0
        self.rearm = False

    def update(self, distance):
        if distance == 0:
            self.air_frames = 0
            self.surface_frames = min(self.surface_frames + 1, SURFACE_CONFIRM_FRAMES)
            if self.surface_frames >= SURFACE_CONFIRM_FRAMES and (
                not self.known or not self.on_surface
            ):
                self.known = True
                self.on_surface = True
                self.rearm = True
        else:
            self.surface_frames = 0
            self.air_frames = min(self.air_frames + 1, SURFACE_CONFIRM_FRAMES)
            if self.air_frames >= SURFACE_CONFIRM_FRAMES and (
                not self.known or self.on_surface
            ):
                was_on_surface = self.known and self.on_surface
                self.known = True
                self.on_surface = False
                self.rearm = was_on_surface


class GyroPointerMathTests(unittest.TestCase):
    def test_nominal_packet_cadence_preserves_integrated_motion(self):
        timestamps = regular_packet_times(1.0)
        emitted, fraction = integrate_packet_rate(
            90.0,
            timestamps,
            COUNTS_PER_DEGREE["normal"],
        )
        self.assertAlmostEqual(
            emitted + fraction,
            90.0 * COUNTS_PER_DEGREE["normal"],
            places=6,
        )
        self.assertEqual(len(timestamps) - 1, 67)

    def test_packet_jitter_preserves_total_motion(self):
        intervals = [0.014, 0.016, 0.015, 0.017, 0.013] * 12
        timestamps = [0.0]
        for interval in intervals:
            timestamps.append(timestamps[-1] + interval)
        emitted, fraction = integrate_packet_rate(
            37.5,
            timestamps,
            COUNTS_PER_DEGREE["slow"],
        )
        expected = 37.5 * sum(intervals) * COUNTS_PER_DEGREE["slow"]
        self.assertAlmostEqual(emitted + fraction, expected, places=6)

    def test_fused_packet_clock_emits_once_per_pair(self):
        clock = GyroPacketClock("fused")
        events = (
            (0.0000, "left", True, False),
            (0.0075, "right", True, True),
            (0.0150, "left", True, True),
            (0.0225, "right", True, True),
            (0.0300, "left", True, True),
            (0.0375, "right", True, True),
        )
        outputs = [
            (side, dt)
            for timestamp, side, left_fresh, right_fresh in events
            if (dt := clock.packet(timestamp, side, left_fresh, right_fresh)) is not None
        ]
        self.assertEqual([side for side, _ in outputs], ["left", "left"])
        self.assertEqual(len(outputs), 2)

    def test_fused_clock_fallback_has_no_handoff_spike(self):
        clock = GyroPacketClock("fused")
        self.assertIsNone(clock.packet(0.000, "left", True, False))
        self.assertAlmostEqual(clock.packet(0.015, "left", True, True), 0.015)
        self.assertIsNone(clock.packet(0.060, "right", False, True))
        self.assertAlmostEqual(clock.packet(0.075, "right", False, True), 0.015)

    def test_duplicate_and_out_of_order_packets_do_not_move_clock_backward(self):
        clock = GyroPacketClock("left")
        self.assertIsNone(clock.packet(1.000, "left", True, False))
        self.assertAlmostEqual(clock.packet(1.015, "left", True, False), 0.015)
        self.assertIsNone(clock.packet(1.015, "left", True, False))
        self.assertIsNone(clock.packet(1.014, "left", True, False))
        self.assertAlmostEqual(clock.packet(1.030, "left", True, False), 0.015)

    def test_stale_gap_is_dropped_instead_of_accumulated(self):
        clock = GyroPacketClock("right")
        self.assertIsNone(clock.packet(2.000, "right", False, True))
        self.assertIsNone(clock.packet(2.100, "right", False, True))
        self.assertAlmostEqual(clock.packet(2.115, "right", False, True), 0.015)

    def test_speed_presets_change_speed_not_reachability(self):
        for name, scale in COUNTS_PER_DEGREE.items():
            emitted, fraction = integrate_rate(90.0, 1.0, scale)
            self.assertEqual(emitted, round(90.0 * scale), name)
            self.assertAlmostEqual(fraction, 0.0, places=6)
        self.assertLess(COUNTS_PER_DEGREE["slow"], COUNTS_PER_DEGREE["normal"])
        self.assertLess(COUNTS_PER_DEGREE["normal"], COUNTS_PER_DEGREE["fast"])

    def test_gain_is_display_independent(self):
        self.assertEqual(COUNTS_PER_DEGREE["normal"], 120.0)

    def test_fractional_carry_preserves_slow_motion(self):
        emitted, fraction = integrate_rate(0.25, 2.0, COUNTS_PER_DEGREE["normal"])
        self.assertEqual(emitted, 60)
        self.assertAlmostEqual(fraction, 0.0, places=6)

    def test_rightward_yaw_moves_pointer_right(self):
        dx, _ = gyro_pointer_delta(0.0, 20.0, 0.1, 1.0)
        self.assertGreater(dx, 0.0)

    def test_rightward_yaw_moves_virtual_stick_right(self):
        x, y = gyro_right_stick(0.0, 20.0, 0.75, 180.0, 0.12, 1.0)
        self.assertGreater(x, 0.0)
        self.assertEqual(y, 0.0)

    def test_upward_pitch_moves_virtual_stick_up(self):
        x, y = gyro_right_stick(20.0, 0.0, 0.75, 180.0, 0.12, 1.0)
        self.assertEqual(x, 0.0)
        self.assertLess(y, 0.0)

    def test_virtual_stick_centers_below_activation_rate(self):
        self.assertEqual(
            gyro_right_stick(0.0, 0.5, 0.75, 180.0, 0.12, 1.0),
            (0.0, 0.0),
        )

    def test_virtual_stick_reaches_full_scale(self):
        output = gyro_right_stick(0.0, 180.0, 0.75, 180.0, 0.12, 1.0)
        self.assertAlmostEqual(math.hypot(*output), 1.0)

    def test_virtual_stick_minimum_output_clears_game_deadzone(self):
        output = gyro_right_stick(0.0, 0.76, 0.75, 180.0, 0.12, 1.0)
        self.assertGreaterEqual(math.hypot(*output), 0.12)

    def test_physical_and_gyro_sticks_blend_additively(self):
        output = blend_right_stick((0.4, 0.0), (0.2, 0.0))
        self.assertAlmostEqual(output[0], 0.6)
        self.assertEqual(output[1], 0.0)

    def test_blended_stick_is_radially_clamped(self):
        output = blend_right_stick((0.9, 0.7), (0.5, 0.4))
        self.assertAlmostEqual(math.hypot(*output), 1.0)

    def test_opposing_gyro_reduces_physical_stick(self):
        output = blend_right_stick((0.6, 0.0), (-0.2, 0.0))
        self.assertLess(output[0], 0.6)

    def test_leftward_yaw_moves_pointer_left(self):
        dx, _ = gyro_pointer_delta(0.0, -20.0, 0.1, 1.0)
        self.assertLess(dx, 0.0)

    def test_both_joycons_agree_on_physical_rightward_yaw(self):
        left_yaw = canonical_pointer_yaw(20.0, "left")
        right_yaw = canonical_pointer_yaw(-20.0, "right")
        left_dx, _ = gyro_pointer_delta(0.0, left_yaw, 0.1, 1.0)
        right_dx, _ = gyro_pointer_delta(0.0, right_yaw, 0.1, 1.0)
        fused_dx, _ = gyro_pointer_delta(0.0, (left_yaw + right_yaw) * 0.5, 0.1, 1.0)
        self.assertGreater(left_dx, 0.0)
        self.assertGreater(right_dx, 0.0)
        self.assertGreater(fused_dx, 0.0)

    def test_both_joycons_agree_on_physical_leftward_yaw(self):
        left_yaw = canonical_pointer_yaw(-20.0, "left")
        right_yaw = canonical_pointer_yaw(20.0, "right")
        left_dx, _ = gyro_pointer_delta(0.0, left_yaw, 0.1, 1.0)
        right_dx, _ = gyro_pointer_delta(0.0, right_yaw, 0.1, 1.0)
        fused_dx, _ = gyro_pointer_delta(0.0, (left_yaw + right_yaw) * 0.5, 0.1, 1.0)
        self.assertLess(left_dx, 0.0)
        self.assertLess(right_dx, 0.0)
        self.assertLess(fused_dx, 0.0)

    def test_player_space_yaw_survives_controller_orientation(self):
        root_half = math.sqrt(0.5)
        flat = player_space_yaw(0.0, -20.0, (0.0, 0.0, 1.0))
        upright = player_space_yaw(-20.0, 0.0, (0.0, 1.0, 0.0))
        diagonal = player_space_yaw(
            -20.0 * root_half,
            -20.0 * root_half,
            (0.0, root_half, root_half),
        )
        self.assertAlmostEqual(flat, -20.0, places=5)
        self.assertAlmostEqual(upright, -20.0, places=5)
        self.assertAlmostEqual(diagonal, -20.0, places=5)

    def test_retained_gravity_rejects_translational_acceleration(self):
        retained_gravity = (0.0, 0.0, 1.0)
        contaminated_accel = (0.0, 0.5, 1.0)
        self.assertAlmostEqual(player_space_yaw(-20.0, 0.0, retained_gravity), 0.0)
        self.assertLess(raw_accel_player_space_yaw(-20.0, 0.0, contaminated_accel), -10.0)
        updated = update_gravity(retained_gravity, (0.0, 0.0, 0.0), contaminated_accel, 1 / 66.67)
        self.assertEqual(updated, retained_gravity)

    def test_fused_gravity_corrects_small_stationary_drift(self):
        tilted_five_degrees = (0.0, math.sin(math.radians(5.0)), math.cos(math.radians(5.0)))
        updated = update_gravity((0.0, 0.0, 1.0), (0.0, 0.0, 0.0), tilted_five_degrees, 1 / 66.67)
        self.assertGreater(updated[1], 0.0)
        self.assertLess(updated[1], tilted_five_degrees[1])

    def test_time_aligned_fusion_does_not_cancel_a_reversal(self):
        # Left has already received the reversal packet; Right is one packet
        # behind. Both represented +120 deg/s at the shared timestamp.
        left = (0.985, 120.0, 1.000, -120.0)
        right = (0.970, 120.0, 0.985, 120.0)
        self.assertAlmostEqual(fused_rate(left, right), 120.0)
        self.assertEqual((left[3] + right[3]) * 0.5, 0.0)

    def test_fused_reversal_handles_expected_ble_phase_offsets(self):
        target = 1.0
        for offset in (0.000, 0.0075, 0.015, 0.030):
            history = [
                (target - 0.015, 120.0),
                (target, 120.0),
                (target + 0.015, -120.0),
                (target + 0.030, -120.0),
            ]
            with self.subTest(offset=offset):
                available = [entry for entry in history if entry[0] <= target + offset]
                self.assertAlmostEqual(rate_at_history(available, target), 120.0)

    def test_fusion_averages_without_doubling(self):
        left = (0.985, 20.0, 1.000, 20.0)
        right = (0.985, 24.0, 1.000, 24.0)
        self.assertEqual(fused_rate(left, right), 22.0)

    def test_closed_square_has_no_hidden_pointer_state(self):
        paths = (
            ((200, 0), (0, 200), (-200, 0), (0, -200)),
            ((-200, 0), (0, -200), (200, 0), (0, 200)),
            ((0, -200), (200, 0), (0, 200), (-200, 0)),
            ((0, 200), (-200, 0), (0, -200), (200, 0)),
        )
        for path in paths:
            position = (500, 500)
            for delta in path:
                position = clamp_cursor(position, delta, (1000, 1000))
            with self.subTest(path=path):
                self.assertEqual(position, (500, 500))

    def test_edge_overshoot_is_discarded_and_reversal_moves_immediately(self):
        position = clamp_cursor((900, 500), (500, 0), (1000, 1000))
        self.assertEqual(position, (1000, 500))
        position = clamp_cursor(position, (-1, 0), (1000, 1000))
        self.assertEqual(position, (999, 500))

    def test_corner_chain_reaches_each_target_without_axis_lock(self):
        position = (500, 500)
        targets = ((1000, 0), (0, 1000), (0, 0), (1000, 1000))
        for target in targets:
            delta = (target[0] - position[0], target[1] - position[1])
            position = clamp_cursor(position, delta, (1000, 1000))
            self.assertEqual(position, target)

    def test_single_surface_glitch_does_not_pause(self):
        gate = SurfaceGate()
        for distance in (12, 12, 12, 0, 12):
            gate.update(distance)
        self.assertTrue(gate.known)
        self.assertFalse(gate.on_surface)
        self.assertFalse(gate.rearm)

    def test_surface_and_pickup_require_consecutive_evidence(self):
        gate = SurfaceGate()
        for distance in (12, 12, 12, 0, 0, 0):
            gate.update(distance)
        self.assertTrue(gate.on_surface)
        self.assertTrue(gate.rearm)
        for distance in (12, 12):
            gate.update(distance)
        self.assertTrue(gate.on_surface)
        gate.update(12)
        self.assertFalse(gate.on_surface)

    def test_calibrated_airborne_slow_motion_is_not_bias_input(self):
        bias_valid = True
        manual_pending = False
        surface_known = True
        on_surface = False
        may_update_bias = not (
            bias_valid and not manual_pending and (not surface_known or not on_surface)
        )
        self.assertFalse(may_update_bias)

    def test_stale_sample_boundary(self):
        now = 10.0
        self.assertTrue(now - (now - FRESHNESS_SECONDS + 0.0001) <= FRESHNESS_SECONDS)
        self.assertFalse(now - (now - FRESHNESS_SECONDS - 0.001) <= FRESHNESS_SECONDS)

    def test_continuous_activation_ignores_button_state(self):
        activation = GyroActivationModel(mode="continuous")
        activation.set_master_enabled(True)
        self.assertTrue(activation.update(set()))

    def test_hold_activation_defaults_to_zl(self):
        activation = GyroActivationModel()
        activation.set_master_enabled(True)
        self.assertFalse(activation.update(set()))
        self.assertTrue(activation.update({"zl"}))
        self.assertFalse(activation.update(set()))

    def test_hold_activation_uses_or_semantics(self):
        activation = GyroActivationModel(slots=("zl", "zr", "a"))
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl", "a"}))
        self.assertTrue(activation.update({"a"}))
        self.assertFalse(activation.update(set()))

    def test_toggle_activation_fires_once_per_rising_edge(self):
        activation = GyroActivationModel(mode="toggle")
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl"}))
        self.assertTrue(activation.update({"zl"}))
        self.assertTrue(activation.update(set()))
        self.assertFalse(activation.update({"zl"}))

    def test_toggle_duplicate_slots_only_toggle_once(self):
        activation = GyroActivationModel(mode="toggle", slots=("zl", "zl", "zl"))
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl"}))

    def test_toggle_simultaneous_buttons_only_toggle_once(self):
        activation = GyroActivationModel(mode="toggle", slots=("zl", "zr", "a"))
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl", "zr", "a"}))

    def test_toggle_can_change_while_another_activation_button_is_held(self):
        activation = GyroActivationModel(mode="toggle", slots=("zl", "zr", "none"))
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl"}))
        self.assertFalse(activation.update({"zl", "zr"}))

    def test_disabling_master_clears_toggle_latch(self):
        activation = GyroActivationModel(mode="toggle")
        activation.set_master_enabled(True)
        self.assertTrue(activation.update({"zl"}))
        activation.set_master_enabled(False)
        self.assertFalse(activation.update(set()))
        activation.set_master_enabled(True)
        self.assertFalse(activation.update(set()))

    def test_activation_buttons_are_not_removed_from_gamepad_reports(self):
        source = (Path(__file__).parents[1] / "JoyCon2Mac" / "main.mm").read_text()
        self.assertNotIn("g_gyroConsumed", source)
        self.assertNotIn("gyroConsumedMask", source)

    def test_gyro_stick_scroll_matches_optical_direction_and_rate(self):
        self.assertEqual(integrate_gyro_scroll(32767, 1.0), 22)
        self.assertEqual(integrate_gyro_scroll(-32767, 1.0), -22)
        self.assertEqual(integrate_gyro_scroll(SCROLL_DEADZONE, 1.0), 0)

    def test_pickup_requires_short_stationary_rearm(self):
        self.assertFalse(0.149 >= GYRO_REARM_SECONDS)
        self.assertTrue(0.150 >= GYRO_REARM_SECONDS)

    def test_optical_gesture_uses_dominant_axis(self):
        self.assertIsNone(optical_gesture_direction(59.0, -59.0))
        self.assertEqual(optical_gesture_direction(-80.0, 20.0), "left")
        self.assertEqual(optical_gesture_direction(80.0, 20.0), "right")
        self.assertEqual(optical_gesture_direction(20.0, -80.0), "up")
        self.assertEqual(optical_gesture_direction(20.0, 80.0), "down")

    def test_optical_gesture_uses_hid_keyboard_arrow_usages(self):
        self.assertEqual(CONTROL_ARROW_USAGES["right"], 0x4F)
        self.assertEqual(CONTROL_ARROW_USAGES["left"], 0x50)
        self.assertEqual(CONTROL_ARROW_USAGES["down"], 0x51)
        self.assertEqual(CONTROL_ARROW_USAGES["up"], 0x52)

    def test_keyboard_chord_has_observable_key_dwell(self):
        self.assertGreaterEqual(GESTURE_KEY_DWELL_SECONDS, 0.020)
        self.assertLessEqual(GESTURE_KEY_DWELL_SECONDS, 0.100)


if __name__ == "__main__":
    unittest.main()
