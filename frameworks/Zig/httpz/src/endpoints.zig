const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const datetimez = @import("datetimez");
const mustache = @import("mustache");

const Thread = std.Thread;
const Mutex = Thread.Mutex;
const template = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>{{#fortunes}}<tr><td>{{id}}</td><td>{{message}}</td></tr>{{/fortunes}}</table></body></html>";

pub const Global = struct {
    pool: *pg.Pool,
    rand: *std.rand.Random,
    mutex: std.Thread.Mutex = .{},
};

const World = struct {
    id: i32,
    randomNumber: i32,
};

const Fortune = struct {
    id: i32,
    message: []const u8,
};

pub fn plaintext(_: *Global, _: *httpz.Request, res: *httpz.Response) !void {
    try setHeaders(res);

    res.content_type = .TEXT;
    res.body = "Hello, World!";
}

pub fn json(_: *Global, _: *httpz.Request, res: *httpz.Response) !void {
    try setHeaders(res);

    try res.json(.{ .message = "Hello, World!" }, .{});
}

pub fn db(global: *Global, _: *httpz.Request, res: *httpz.Response) !void {
    try setHeaders(res);

    global.mutex.lock();
    const random_number = 1 + (global.rand.uintAtMostBiased(u32, 9999));
    global.mutex.unlock();

    const world = getWorld(global.pool, random_number) catch |err| {
        std.debug.print("Error querying database: {}\n", .{err});
        return;
    };

    try res.json(world, .{});
}

pub fn fortune(global: *Global, _: *httpz.Request, res: *httpz.Response) !void {
    try setHeaders(res);

    const fortunes_html = try getFortunesHtml(res.arena, global.pool);

    res.header("content-type", "text/html; charset=utf-8");
    res.body = fortunes_html;
}

fn getWorld(pool: *pg.Pool, random_number: u32) !World {
    var conn = try pool.acquire();
    defer conn.release();

    const row_result = try conn.row("SELECT id, randomNumber FROM World WHERE id = $1", .{random_number});

    var row = row_result.?;
    defer row.deinit() catch {};

    return World{ .id = row.get(i32, 0), .randomNumber = row.get(i32, 1) };
}

threadlocal var date_buff: [128]u8 = undefined;
threadlocal var date_str: []u8 = undefined;
threadlocal var prev_time: ?datetimez.datetime.Datetime = null;

fn setHeaders(res: *httpz.Response) !void {
    res.header("Server", "Httpz");

    const cur_time = datetimez.datetime.Datetime.now();
    if (prev_time == null or cur_time.sub(prev_time.?).totalSeconds() >= 1) {
        // Wed, 17 Apr 2013 12:00:00 GMT
        // Return date in ISO format YYYY-MM-DD
        const TB_DATE_FMT = "{s:0>3}, {d:0>2} {s:0>3} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT";
        date_str = try std.fmt.bufPrint(&date_buff, TB_DATE_FMT, .{
            cur_time.date.weekdayName()[0..3],
            cur_time.date.day,
            cur_time.date.monthName()[0..3],
            cur_time.date.year,
            cur_time.time.hour,
            cur_time.time.minute,
            cur_time.time.second,
        });
        prev_time = cur_time;
    }

    res.header("Date", date_str);
}

fn getFortunesHtml(allocator: std.mem.Allocator, pool: *pg.Pool) ![]const u8 {
    const fortunes = try getFortunes(allocator, pool);
    // TODO: get newer version where bug ix fixed
    // const comptime_template = comptime mustache.parseComptime(template, .{}, .{});

    const html = try mustache.allocRenderText(allocator, template, .{ .fortunes = fortunes });
    return html;
}

fn getFortunes(allocator: std.mem.Allocator, pool: *pg.Pool) ![]const Fortune {
    var conn = try pool.acquire();
    defer conn.release();

    var rows = try conn.queryOpts("SELECT id, message FROM Fortune", .{}, .{ .allocator = allocator });
    defer rows.deinit();

    var fortunes = std.ArrayList(Fortune).init(allocator);
    defer fortunes.deinit();

    while (try rows.next()) |row| {
        const current_fortune = try row.to(Fortune, .{ .allocator = allocator });
        try fortunes.append(current_fortune);
    }

    const zero_fortune = Fortune{ .id = 0, .message = "Additional fortune added at request time." };
    try fortunes.append(zero_fortune);

    const fortunes_slice = try fortunes.toOwnedSlice();
    std.mem.sort(Fortune, fortunes_slice, {}, cmpFortuneByMessage);

    return fortunes_slice;
}

fn cmpFortuneByMessage(_: void, a: Fortune, b: Fortune) bool {
    return std.mem.order(u8, a.message, b.message).compare(std.math.CompareOperator.lt);
}

fn deescapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&#32;")) {
            try output.append(' ');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#34;")) {
            try output.append('"');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#38;")) {
            try output.append('&');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#39;")) {
            try output.append('\'');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#40;")) {
            try output.append('(');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#41;")) {
            try output.append(')');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#43;")) {
            try output.append('+');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#44;")) {
            try output.append(',');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#46;")) {
            try output.append('.');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#47;")) {
            try output.append('/');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#58;")) {
            try output.append(':');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#59;")) {
            try output.append(';');
            i += 5;
        } else {
            try output.append(input[i]);
            i += 1;
        }
    }

    return output.toOwnedSlice();
}
