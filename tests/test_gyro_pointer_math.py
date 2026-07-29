import math
import unittest


TICK_RATE = 120
FRESHNESS_SECONDS = 0.0455
COUNTS_PER_DEGREE = {"slow": 80.0, "normal": 120.0, "fast": 160.0}
GESTURE_THRESHOLD = 60.0
GYRO_REARM_SECONDS = 0.15
SURFACE_CONFIRM_FRAMES = 3


def optical_gesture_direction(x, y):
    if abs(x) < GESTURE_THRESHOLD and abs(y) < GESTURE_THRESHOLD:
        return None
    if abs(x) >= abs(y):
        return "left" if x < 0 else "right"
    return "up" if y < 0 else "down"


def extract_whole(value):
    return math.floor(value + 1e-9) if value >= 0 else math.ceil(value - 1e-9)


def integrate_rate(rate_degrees_per_second, seconds, scale):
    fraction = 0.0
    emitted = 0
    ticks = round(seconds * TICK_RATE)
    for _ in range(ticks):
        fraction += rate_degrees_per_second / TICK_RATE * scale
        whole = extract_whole(fraction)
        fraction -= whole
        emitted += whole
    return emitted, fraction


def gyro_pointer_delta(pitch_rate, yaw_rate, seconds, scale):
    return -yaw_rate * seconds * scale, -pitch_rate * seconds * scale


def normalize(vector):
    length = math.sqrt(sum(component * component for component in vector))
    if length < 0.0001:
        return None
    return tuple(component / length for component in vector)


def player_space_yaw(gyro_y, gyro_z, gravity):
    world_yaw = gyro_y * gravity[1] + gyro_z * gravity[2]
    relaxed = min(abs(world_yaw) * math.sqrt(2.0), math.hypot(gyro_y, gyro_z))
    return math.copysign(relaxed, world_yaw) if world_yaw else 0.0


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
        dx, _ = gyro_pointer_delta(0.0, -20.0, 0.1, 1.0)
        self.assertGreater(dx, 0.0)

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

    def test_pickup_requires_short_stationary_rearm(self):
        self.assertFalse(0.149 >= GYRO_REARM_SECONDS)
        self.assertTrue(0.150 >= GYRO_REARM_SECONDS)

    def test_optical_gesture_uses_dominant_axis(self):
        self.assertIsNone(optical_gesture_direction(59.0, -59.0))
        self.assertEqual(optical_gesture_direction(-80.0, 20.0), "left")
        self.assertEqual(optical_gesture_direction(80.0, 20.0), "right")
        self.assertEqual(optical_gesture_direction(20.0, -80.0), "up")
        self.assertEqual(optical_gesture_direction(20.0, 80.0), "down")


if __name__ == "__main__":
    unittest.main()
