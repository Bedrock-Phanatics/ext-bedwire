//! Everything below the PHP boundary. Nothing here touches Zend, so it is tested without PHP.
const std = @import("std");

const host = @import("host.zig");

pub const Host = host.Host;
pub const Config = host.Config;
pub const Event = host.Event;
pub const Reason = host.Reason;
pub const Delivered = host.Delivered;
pub const SendError = host.SendError;
pub const Statistics = host.Statistics;
pub const max_packets_per_batch = host.max_packets_per_batch;
pub const max_status_text = host.max_status_text;
pub const max_ice_servers = host.max_ice_servers;
pub const max_trusted_keys = host.max_trusted_keys;
pub const stat_names = host.stat_names;
pub const protocol = @import("bedwire").protocol;
pub const Ring = @import("ring.zig").Ring;
pub const nbt = @import("nbt.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("ring.zig");
    _ = @import("nbt.zig");
    _ = @import("worker.zig");
}
