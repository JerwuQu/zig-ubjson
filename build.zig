const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const main_tests = b.addTest("ubjson.zig");
    main_tests.setBuildMode(b.standardReleaseOptions());

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
