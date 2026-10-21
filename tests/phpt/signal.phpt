--TEST--
Another thread can wait on a server's event signal, and the handle dies with the server
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\Server;

$server = new Server("127.0.0.1", 0, ["authentication" => false]);
$signal = $server->eventSignal();
var_dump(is_int($signal));
$start = hrtime(true);
$seen = Server::waitForEvents($signal, 0, 50);
var_dump($seen === 0, (hrtime(true) - $start) >= 40e6);
var_dump(Server::waitForEvents($signal, $seen + 1, 0) === $seen);
var_dump(Server::waitForEvents(123456789, 0, 0));
$server->stop(0);
unset($server);
var_dump(Server::waitForEvents($signal, 0, 0));
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
NULL
NULL
