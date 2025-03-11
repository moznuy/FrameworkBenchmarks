const std = @import("std");
const regex = @import("regex");
const pg = @import("pg");

const Allocator = std.mem.Allocator;
const Pool = pg.Pool;
const ArrayList = std.ArrayList;

pub const InititilizedPool = struct {
    allocator: Allocator,
    pool: *pg.Pool,
    info: OwnedConnectionInfo,

    pub fn deinit(self: InititilizedPool) void {
        self.pool.deinit();
        self.info.deinit(self.allocator);
    }
};

pub fn init(allocator: Allocator) !InititilizedPool {
    const info = try parsePostgresConnStr(allocator);
    errdefer info.deinit(allocator);

    const pg_pool = try Pool.init(allocator, .{
        // TODO: magic number?
        .size = 56,
        .connect = .{
            .port = info.port,
            .host = info.hostname,
        },
        .auth = .{
            .username = info.username,
            .database = info.database,
            .password = info.password,
        },
        .timeout = 10_000,
    });

    return .{
        .allocator = allocator,
        .pool = pg_pool,
        .info = info,
    };
}

const OwnedConnectionInfo = struct {
    username: []const u8,
    password: []const u8,
    hostname: []const u8,
    port: u16,
    database: []const u8,

    fn deinit(self: OwnedConnectionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password);
        allocator.free(self.hostname);
        allocator.free(self.database);
    }
};

fn parsePostgresConnStr(allocator: Allocator) !OwnedConnectionInfo {
    const pg_port = try getEnvVar(allocator, "PG_PORT", "5432");
    const port = try std.fmt.parseInt(u16, pg_port, 0);
    allocator.free(pg_port);

    return OwnedConnectionInfo{
        .username = try getEnvVar(allocator, "PG_USER", "benchmarkdbuser"),
        .password = try getEnvVar(allocator, "PG_PASS", "benchmarkdbpass"),
        .hostname = try getEnvVar(allocator, "PG_HOST", "localhost"),
        .port = port,
        .database = try getEnvVar(allocator, "PG_DB", "hello_world"),
    };
}

fn getEnvVar(allocator: Allocator, name: []const u8, default: []const u8) ![]const u8 {
    const env_var = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, default),
        error.OutOfMemory => return err,
        error.InvalidWtf8 => return err,
    };
    return env_var;
}
