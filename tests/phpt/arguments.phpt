--TEST--
Invalid arguments are rejected with stable errors
--EXTENSIONS--
bedwire
--FILE--
<?php
const AD = "MCPE;phpt;2193;1.0;0;10;1;w;Survival;1;19132;19133;";

function attempt(callable $call): void {
    try {
        $call();
        echo "ok\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

attempt(fn() => new Bedwire\Server("127.0.0.1", 70000, AD));
attempt(fn() => new Bedwire\Server("localhost", 0, AD));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, ""));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["max_sessions" => "8"]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["max_sessions" => -1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["max_sessions" => 0]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["encryption" => 1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["raw_prefixes" => [1]]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, [5 => 1]));
attempt(fn() => new Bedwire\Server("127.0.0.1", 0, AD, ["unknown_option" => 1]));

$server = new Bedwire\Server("127.0.0.1", 0, AD, ["encryption" => false, "raw_prefixes" => ["\xfe\xfd"], "guid" => 1234]);
attempt(fn() => $server->poll(0));
attempt(fn() => $server->poll(16, -1));
attempt(fn() => $server->sendBatch(1, []));
attempt(fn() => $server->sendBatch(1, [""]));
attempt(fn() => $server->sendBatch(1, ["a", 2]));
attempt(fn() => $server->sendBatch(1, array_fill(0, 1025, "a")));
attempt(fn() => $server->send(1, str_repeat("a", 5 * 1024 * 1024)));
attempt(fn() => $server->enableEncryption(1, "\x03", "short"));
attempt(fn() => $server->blockAddress("not-an-ip"));
attempt(fn() => $server->sendRaw("127.0.0.1", -1, "x"));
attempt(fn() => $server->setAdvertisement(str_repeat("a", 2000)));
attempt(fn() => $server->stop(-1));
$server->stop(0);
?>
--EXPECT--
ValueError: Bedwire\Server::__construct(): Argument #2 ($port) must be between 0 and 65535
ValueError: Bedwire\Server::__construct(): Argument #1 ($address) must be an IP address
ValueError: Bedwire\Server::__construct(): Argument #4 ($options) contains an out-of-range value
TypeError: Bedwire\Server::__construct(): Argument #4 ($options) option "max_sessions" must be int
ValueError: Bedwire\Server::__construct(): Argument #4 ($options) option "max_sessions" must not be negative
ValueError: Bedwire\Server::__construct(): Argument #4 ($options) contains an out-of-range value
TypeError: Bedwire\Server::__construct(): Argument #4 ($options) option "encryption" must be bool
TypeError: Bedwire\Server::__construct(): Argument #4 ($options) option "raw_prefixes" must be a list of strings
ValueError: Bedwire\Server::__construct(): Argument #4 ($options) must use string keys
ValueError: Bedwire\Server::__construct(): Argument #4 ($options) has unknown option "unknown_option"
ValueError: Bedwire\Server::poll(): Argument #1 ($maxEvents) must be between 1 and 1048576
ValueError: Bedwire\Server::poll(): Argument #2 ($timeoutMs) must be between 0 and 4294967295
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must not be empty
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must not be empty
TypeError: Bedwire\Server::sendBatch(): Argument #2 ($packets) must contain only strings
ValueError: Bedwire\Server::sendBatch(): Argument #2 ($packets) has more than 1024 packets
ValueError: Bedwire\Server::send(): Argument #2 ($packet) exceeds the maximum batch size
ValueError: Bedwire\Server::enableEncryption(): Argument #3 ($key) must be exactly 32 bytes
ValueError: Bedwire\Server::blockAddress(): Argument #1 ($address) must be an IP address
ValueError: Bedwire\Server::sendRaw(): Argument #2 ($port) must be between 0 and 65535
ValueError: Bedwire\Server::setAdvertisement(): Argument #1 ($advertisement) has an invalid length
ValueError: Bedwire\Server::stop(): Argument #1 ($timeoutMs) must be between 0 and 4294967295
