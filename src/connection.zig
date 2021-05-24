const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const PreparedStatement = @import("prepared_statement.zig").PreparedStatement;
const ResultSet = @import("result_set.zig").ResultSet;
const FetchResult = @import("result_set.zig").FetchResult;

const sql_parameter = @import("parameter.zig");
const ParameterBucket = sql_parameter.ParameterBucket;

// @todo Move this to a general "catalog data structs" file
pub const Column = struct {
    table_category: ?[]const u8,
    table_schema: ?[]const u8,
    table_name: []const u8,
    column_name: []const u8,
    data_type: u16,
    type_name: []const u8,
    column_size: ?u32,
    buffer_length: ?u32,
    decimal_digits: ?u16,
    num_prec_radix: ?u16,
    nullable: odbc.Types.Nullable,
    remarks: ?[]const u8,
    column_def: ?[]const u8,
    sql_data_type: odbc.Types.SqlType,
    sql_datetime_sub: ?u16,
    char_octet_length: ?u32,
    ordinal_position: u32,
    is_nullable: ?[]const u8,

    pub fn deinit(self: *Column, allocator: *Allocator) void {
        if (self.table_category) |tc| allocator.free(tc);
        if (self.table_schema) |ts| allocator.free(ts);
        allocator.free(self.table_name);
        allocator.free(self.column_name);
        allocator.free(self.type_name);
        if (self.remarks) |r| allocator.free(r);
        if (self.column_def) |cd| allocator.free(cd);
        if (self.is_nullable) |in| allocator.free(in);
    }
};

pub const ConnectionInfo = struct {
    pub const Config = struct {
        driver: ?[]const u8 = null,
        dsn: ?[]const u8 = null,
        username: ?[]const u8 = null,
        password: ?[]const u8 = null,
    };

    attributes: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    /// Initialize a blank `ConnectionInfo` struct with an initialized `attributes` hash map
    /// and arena allocator.
    pub fn init(allocator: *Allocator) ConnectionInfo {
        return .{ 
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Initialize a `ConnectionInfo` using the information provided in the config data.
    pub fn initWithConfig(allocator: *Allocator, config: Config) !ConnectionInfo {
        var connection_info = ConnectionInfo.init(allocator);
        if (config.driver) |driver| try connection_info.setDriver(driver);
        if (config.dsn) |dsn| try connection_info.setDSN(dsn);
        if (config.username) |username| try connection_info.setUsername(username);
        if (config.password) |password| try connection_info.setPassword(password);

        return connection_info;
    }

    pub fn deinit(self: *ConnectionInfo) void {
        self.attributes.deinit();
        self.arena.deinit();
    }

    pub fn setAttribute(self: *ConnectionInfo, attr_name: []const u8, attr_value: []const u8) !void {
        try self.attributes.put(attr_name, attr_value);
    }

    pub fn getAttribute(self: *ConnectionInfo, attr_name: []const u8) ?[]const u8 {
        return self.attributes.get(attr_name);
    }

    pub fn setDriver(self: *ConnectionInfo, driver_value: []const u8) !void {
        try self.setAttribute("DRIVER", driver_value);
    }

    pub fn getDriver(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("DRIVER");
    }

    pub fn setUsername(self: *ConnectionInfo, user_value: []const u8) !void {
        try self.setAttribute("UID", user_value);
    }

    pub fn getUsername(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("UID");
    }

    pub fn setPassword(self: *ConnectionInfo, password_value: []const u8) !void {
        try self.setAttribute("PWD", password_value);
    }

    pub fn getPassword(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("PWD");
    }

    pub fn setDSN(self: *ConnectionInfo, dsn_value: []const u8) !void {
        try self.setAttribute("DSN", dsn_value);
    }

    pub fn getDSN(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("DSN");
    }

    pub fn toConnectionString(self: *ConnectionInfo) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(&self.arena.allocator);
        errdefer string_builder.deinit();
        
        _ = try string_builder.writer().write("ODBC;");

        var attribute_iter = self.attributes.iterator();
        while (attribute_iter.next()) |entry| {
            _ = try string_builder.writer().write(entry.key);
            _ = try string_builder.writer().write("=");
            _ = try string_builder.writer().write(entry.value);
            _ = try string_builder.writer().write(";");
        }

        return string_builder.toOwnedSlice();
    }

    pub fn fromConnectionString(allocator: *Allocator, conn_str: []const u8) !ConnectionInfo {
        var conn_info = ConnectionInfo.init(allocator);

        var attr_start: usize = 0;
        var attr_sep_index: usize = 0;

        var current_index: usize = 0;
        while (current_index < conn_str.len) : (current_index += 1) {
            if (conn_str[current_index] == '=') {
                attr_sep_index = current_index;
                continue;
            }

            if (conn_str[current_index] == ';') {
                const attr_name = conn_str[attr_start..attr_sep_index];
                const attr_value = conn_str[attr_sep_index + 1..current_index];
                try conn_info.setAttribute(attr_name, attr_value);  

                attr_start = current_index + 1;  
            } else if (current_index == conn_str.len - 1) {
                const attr_name = conn_str[attr_start..attr_sep_index];
                const attr_value = conn_str[attr_sep_index + 1..];
                try conn_info.setAttribute(attr_name, attr_value);
            }
        }

        return conn_info;
    }
};

pub const DBConnection = struct {
    environment: odbc.Environment,
    connection: odbc.Connection,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, server_name: []const u8, username: []const u8, password: []const u8) !DBConnection {
        var result: DBConnection = undefined;
        result.allocator = allocator;
        
        result.environment = odbc.Environment.init(allocator) catch |_| return error.EnvironmentError;
        errdefer result.environment.deinit() catch |_| {};
        
        result.environment.setOdbcVersion(.Odbc3) catch |_| return error.EnvironmentError;
        
        result.connection = odbc.Connection.init(allocator, &result.environment) catch |_| return error.ConnectionError;
        errdefer result.connection.deinit() catch |_| {};

        try result.connection.connect(server_name, username, password);

        return result;
    }

    pub fn initWithConnectionString(allocator: *Allocator, connection_string: []const u8) !DBConnection {
        var result: DBConnection = undefined;
        result.allocator = allocator;
        
        result.environment = odbc.Environment.init(allocator) catch |_| return error.EnvironmentError;
        errdefer result.environment.deinit() catch |_| {};
        
        result.environment.setOdbcVersion(.Odbc3) catch |_| return error.EnvironmentError;
        
        result.connection = odbc.Connection.init(allocator, &result.environment) catch |_| return error.ConnectionError;
        errdefer result.connection.deinit() catch |_| {};

        try result.connection.connectExtended(connection_string, .NoPrompt);

        return result;
    }

    pub fn initWithInfo(allocator: *Allocator, connection_info: *ConnectionInfo) !DBConnection {
        return try DBConnection.initWithConnectionString(allocator, try connection_info.toConnectionString());
    }

    pub fn deinit(self: *DBConnection) void {
        self.connection.deinit() catch |_| {};
        self.environment.deinit() catch |_| {};
    }

    pub fn insert(self: *DBConnection, comptime DataType: type, comptime table_name: []const u8, values: []const DataType) !void {
        // @todo Maybe return num rows inserted?
        comptime const num_fields = std.meta.fields(DataType).len;

        const insert_statement = comptime blk: {
            var statement: []const u8 = "INSERT INTO " ++ table_name ++ " (";
            var statement_end: []const u8 = "VALUES (";
            for (std.meta.fields(DataType)) |field, index| {
                statement_end = statement_end ++ "?";
                var column_name: []const u8 = &[_]u8{}; 
                for (field.name) |c| {
                    column_name = column_name ++ [_]u8{std.ascii.toLower(c)};
                }
                statement = statement ++ column_name;
                if (index < num_fields - 1) {
                    statement = statement ++ ", ";
                    statement_end = statement_end ++ ", ";
                }
            }

            statement = statement ++ ") " ++ statement_end ++ ")";
            break :blk statement;
        };

        var prepared_statement = try self.prepareStatement(insert_statement);
        defer prepared_statement.deinit();

        for (values) |value| {
            inline for (std.meta.fields(DataType)) |field, index| {
                try prepared_statement.addParam(index + 1, @field(value, field.name));
            }

            prepared_statement.execute() catch |err| {
                var err_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(err_buf[0..]);
                const errors = try prepared_statement.statement.getErrors(&fba.allocator);
                for (errors) |e| {
                    std.debug.print("Insert Error: {s}\n", .{@tagName(e)});
                }
            };
        }
    }

    pub fn executeDirect(self: *DBConnection, comptime ResultType: type, statement: *odbc.Statement, sql_statement: []const u8, params: anytype) !ResultSet(ResultType) {
        var num_params: usize = 0;
        for (sql_statement) |c| {
            if (c == '?') num_params += 1;
        }

        if (num_params != params.len) return error.InvalidNumParams;

        // var statement = self.getStatement() catch |stmt_err| {
        //     var error_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
        //     var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);

        //     const errors = try self.connection.getErrors(&fba.allocator);

        //     for (errors) |e| {
        //         std.debug.print("Statement init error: {s}\n", .{@tagName(e)});
        //     }
        //     return error.StatementError;
        // };
        // errdefer statement.deinit() catch |_| {};

        var parameter_bucket = try ParameterBucket.init(self.allocator, num_params);
        defer parameter_bucket.deinit();

        inline for (params) |param, index| {
            const stored_param = try parameter_bucket.addParameter(index, param);
            const sql_param = sql_parameter.default(param);
            try statement.bindParameter(
                @intCast(u16, index + 1), 
                .Input, 
                sql_param.c_type, 
                sql_param.sql_type, 
                stored_param.param, 
                sql_param.precision, 
                stored_param.indicator,
            );
        }

        _ = try statement.executeDirect(sql_statement);

        // return try ResultSet(ResultType).init(self.allocator, &statement);
        return try ResultSet(ResultType).init(self.allocator, statement);
    }

    /// Create a prepared statement from the specified SQL statement. 
    pub fn prepareStatement(self: *DBConnection, sql_statement: []const u8) !PreparedStatement {
        var num_params: usize = 0;
        for (sql_statement) |c| {
            if (c == '?') num_params += 1;
        }

        var statement = try self.getStatement();
        errdefer statement.deinit() catch |_| {};

        statement.prepare(sql_statement) catch |prep_err| {
            const diagnostic_records = try statement.getDiagnosticRecords();
            defer {
                for (diagnostic_records) |*r| r.deinit(self.allocator);
                self.allocator.free(diagnostic_records);
            }
            for (diagnostic_records) |*record| {
                const sql_state = odbc.Error.OdbcError.fromString(record.sql_state[0..]);
                // @todo These are good places to put error logging once logging is implemented
                if (sql_state) |state| {
                    std.debug.print("Fetch Error: {s} ({s})\n", .{record.sql_state, @tagName(state)});
                } else |_| {
                    std.debug.print("Fetch Error: {s} (unknown sql_state)\n", .{record.sql_state});
                }

                std.debug.print("Error Message: {s}\n", .{record.error_message});
            }
        };

        return try PreparedStatement.init(self.allocator, statement, num_params);
    }

    /// Get information about the columns of a given table.
    pub fn getColumns(self: *DBConnection, catalog_name: []const u8, schema_name: []const u8, table_name: []const u8) ![]Column {
        var statement = try self.getStatement();
        defer statement.deinit() catch |_| {};

        var result_set = try ResultSet(Column).init(self.allocator, &statement);
        defer result_set.deinit();

        try statement.columns(catalog_name, schema_name, table_name, null);

        return try result_set.getAllRows();
    }

    pub fn getStatement(self: *DBConnection) !odbc.Statement {
        return try odbc.Statement.init(&self.connection, self.allocator);
    }
};

test "ConnectionInfo" {
    const allocator = std.testing.allocator;

    var connection_info = ConnectionInfo.init(allocator);
    defer connection_info.deinit();

    try connection_info.setDriver("A Driver");
    try connection_info.setDSN("Some DSN Value");
    try connection_info.setUsername("User");
    try connection_info.setPassword("Password");
    try connection_info.setAttribute("RandomAttr", "Random Value");

    const connection_string = try connection_info.toConnectionString();

    var derived_conn_info = try ConnectionInfo.fromConnectionString(allocator, connection_string);
    defer derived_conn_info.deinit();

    std.testing.expectEqualStrings("A Driver", derived_conn_info.getDriver().?);
    std.testing.expectEqualStrings("Some DSN Value", derived_conn_info.getDSN().?);
    std.testing.expectEqualStrings("User", derived_conn_info.getUsername().?);
    std.testing.expectEqualStrings("Password", derived_conn_info.getPassword().?);
    std.testing.expectEqualStrings("Random Value", derived_conn_info.getAttribute("RandomAttr").?);
}