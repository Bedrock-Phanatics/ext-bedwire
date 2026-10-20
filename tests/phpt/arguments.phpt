--TEST--
Invalid arguments are rejected with stable errors
--EXTENSIONS--
bedwire
--FILE--
<?php
function attempt(callable $call): void {
    try {
        $call();
        echo "ok\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

attempt(fn() => new Bedwire\Server("127.0.0.1", 70000));
attempt(fn() => new Bedwire\Server("localhost", 0));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => "8"]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => -1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => 0]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["port_range_begin" => 70000]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["port_range_begin" => 5000]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["authentication" => 1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["identity_file" => ""]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, [5 => 1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ["unknown_option" => 1]));

$server = new Bedwire\Server("127.0.0.1", 0, ["authentication" => false, "udp_mux" => false]);
attempt(fn() => $server->poll(0));
attempt(fn() => $server->poll(16, -1));
attempt(fn() => $server->sendBatch(1, []));
attempt(fn() => $server->sendBatch(1, [""]));
attempt(fn() => $server->sendBatch(1, ["a", 2]));
attempt(fn() => $server->sendBatch(1, array_fill(0, 1025, "a")));
attempt(fn() => $server->send(1, str_repeat("a", 5 * 1024 * 1024)));
attempt(fn() => $server->sendPackets(1, [["text"]]));
attempt(fn() => $server->sendPackets(1, [["no_such_packet", []]]));
attempt(fn() => $server->sendPackets(1, [["text", ["localize" => "yes"]]]));
attempt(fn() => $server->setStatus(str_repeat("a", 300), "level", 10));
attempt(fn() => $server->setStatus("name", "level", -1));
attempt(fn() => $server->setStatus("name", "level", 10, 3));
attempt(fn() => $server->stop(-1));
$server->stop(0);
?>
--EXPECT--
ValueError: Bedwire\Server::__construct(): Argument #2 ($port) must be between 0 and 65535
ValueError: Bedwire\Server::__construct(): Argument #1 ($address) must be an IP address
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
TypeError: Bedwire\Server::sendPackets(): Argument #2 ($packets) must contain [packet, fields] pairs
ValueError: Bedwire\Server::sendPackets(): Argument #2 ($packets) must use known packet names
ValueError: Bedwire\Server::sendPackets(): Argument #2 ($packets) localize must be of type bool, string given
ValueError: Bedwire\Server::setStatus(): Argument #1 ($name) must be valid UTF-8 of at most 256 bytes
ValueError: Bedwire\Server::setStatus(): Argument #3 ($maxPlayers) must not be negative
ValueError: Bedwire\Server::setStatus(): Argument #4 ($gameType) must be between 0 and 2
ValueError: Bedwire\Server::stop(): Argument #1 ($timeoutMs) must be between 0 and 4294967295
