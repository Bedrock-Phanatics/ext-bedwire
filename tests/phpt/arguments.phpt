--TEST--
Invalid arguments are rejected with stable errors
--EXTENSIONS--
bedwire
--FILE--
<?php
require __DIR__ . '/server.inc';

function attempt(callable $call): void {
    try {
        $call();
        echo "ok\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

attempt(fn() => new Bedwire\Server("127.0.0.1", 70000, OPTIONS));
attempt(fn() => new Bedwire\Server("localhost", 0, OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, []));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["protocol_version" => 1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["minecraft_version" => "1.26.60"]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["protocol_version" => "1"] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["protocol_version" => 0] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["protocol_version" => 1 << 31] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["minecraft_version" => 1] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["minecraft_version" => ""] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["minecraft_version" => str_repeat("1", 33)] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["serverbound_packets" => 1] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["serverbound_packets" => ["1"]] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["serverbound_packets" => [1024]] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["serverbound_packets" => [-1]] + OPTIONS));
attempt(function () {
    (new Bedwire\Server("127.0.0.1", 0, ["serverbound_packets" => [0, 9, 1023]] + OPTIONS))->stop(0);
});
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => "8"] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => -1] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => 0] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["port_range_begin" => 70000] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["port_range_begin" => 5000] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["authentication" => 1] + VERSION));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["identity_file" => ""] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, [5 => 1] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["unknown_option" => 1] + OPTIONS));

$server = new Bedwire\Server("127.0.0.1", 0, ["udp_mux" => false] + OPTIONS);
attempt(fn() => $server->poll(0));
attempt(fn() => $server->poll(16, -1));
attempt(fn() => $server->sendBatch(1, []));
attempt(fn() => $server->sendBatch(1, [""]));
attempt(fn() => $server->sendBatch(1, ["a", 2]));
attempt(fn() => $server->sendBatch(1, array_fill(0, 1025, "a")));
attempt(fn() => $server->send(1, str_repeat("a", 5 * 1024 * 1024)));
attempt(fn() => $server->sendRawBatch(1, "	"));
attempt(fn() => $server->sendRawBatch(1, ""));
attempt(fn() => $server->sendRawBatch(1, "	", 3));
attempt(fn() => $server->sendUnreliable(1, str_repeat("a", 70000)));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["ice_servers" => "stun:x"] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["ice_servers" => [""]] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["bind_address" => "not an ip"] + OPTIONS));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["trusted_identity_keys" => array_fill(0, 65, "k")] + OPTIONS));
attempt(fn() => $server->setStatus(str_repeat("a", 300), "level", 10));
attempt(fn() => $server->setStatus("name", "level", -1));
attempt(fn() => $server->setStatus("name", "level", 10, 3));
attempt(fn() => $server->stop(-1));
$server->stop(0);
?>
--EXPECT--
ValueError: Bedwire\Server::__construct(): Argument #2 ($port) must be between 0 and 65535
ValueError: Bedwire\Server::__construct(): Argument #1 ($address) must be an IP address
ArgumentCountError: Bedwire\Server::__construct() expects exactly 3 arguments, 2 given
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) must contain option "protocol_version"
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) must contain option "minecraft_version"
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) must contain option "protocol_version"
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "protocol_version" must be int
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "protocol_version" must be between 1 and 2147483647
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "protocol_version" must be between 1 and 2147483647
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "minecraft_version" must be string
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "minecraft_version" must be valid UTF-8 of 1 to 32 bytes
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "minecraft_version" must be valid UTF-8 of 1 to 32 bytes
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "serverbound_packets" must be a list of ints
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "serverbound_packets" must be a list of ints
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "serverbound_packets" must only contain IDs from 0 to 1023
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "serverbound_packets" must only contain IDs from 0 to 1023
ok
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "max_sessions" must be int
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "max_sessions" must not be negative
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) contains an out-of-range value
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "port_range_begin" is out of range
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) contains an out-of-range value
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "authentication" must be bool
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "identity_file" must be a path
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) must use string keys
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) has unknown option "unknown_option"
ValueError: Bedwire\Server::poll(): Argument #1 ($maxEvents) must be between 1 and 1048576
ValueError: Bedwire\Server::poll(): Argument #2 ($timeoutMs) must be between 0 and 4294967295
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must not be empty
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must not be empty
TypeError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must contain only strings
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) has more than 1024 packets
ValueError: Bedwire\Server::send(): Argument #2 ($packet) exceeds the maximum batch size
ValueError: Bedwire\Server::sendRawBatch(): Argument #2 ($batch) is not a batch of varint length-prefixed packets
ValueError: Bedwire\Server::sendRawBatch(): Argument #2 ($batch) must not be empty
ValueError: Bedwire\Server::sendRawBatch(): Argument #3 ($offset) is past the end of the batch
ValueError: Bedwire\Server::sendUnreliable(): Argument #2 ($payload) exceeds the maximum batch size
TypeError: Bedwire\Server::__construct(): Argument #3 ($options) option "ice_servers" must be a list of strings
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "ice_servers" has an empty or invalid entry
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "bind_address" must be an IP address
ValueError: Bedwire\Server::__construct(): Argument #3 ($options) option "trusted_identity_keys" has too many entries
ValueError: Bedwire\Server::setStatus(): Argument #1 ($name) must be valid UTF-8 of at most 256 bytes
ValueError: Bedwire\Server::setStatus(): Argument #3 ($maxPlayers) must not be negative
ValueError: Bedwire\Server::setStatus(): Argument #4 ($gameType) must be between 0 and 2
ValueError: Bedwire\Server::stop(): Argument #1 ($timeoutMs) must be between 0 and 4294967295
