// The root lets the timing suite and the private encoder share one module.
test {
    _ = @import("bench/budgets.zig");
}
