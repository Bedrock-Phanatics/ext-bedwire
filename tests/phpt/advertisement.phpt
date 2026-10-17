--TEST--
Unconnected pongs carry the advertisement and its runtime updates
--EXTENSIONS--
bedwire
--FILE--
<?php
const MAGIC = "\x00\xff\xff\x00\xfe\xfe\xfe\xfe\xfd\xfd\xfd\xfd\x12\x34\x56\x78";

function pong($socket): ?array {
    fwrite($socket, "\x01" . pack("J", 42) . MAGIC . pack("J", 7));
    $read = [$socket];
    $none = null;
    if (stream_select($read, $none, $none, 1) !== 1) {
        return null;
    }
    $data = fread($socket, 2048);
    if ($data === false || $data === "" || $data[0] !== "\x1c") {
        return null;
    }
    $length = unpack("n", substr($data, 33, 2))[1];
    return [unpack("J", substr($data, 9, 8))[1], substr($data, 35, $length)];
}

$first = "MCPE;first;2193;1.0;0;10;1;w;Survival;1;19132;19133;";
$server = new Bedwire\Server("127.0.0.1", 0, $first, ["guid" => 99]);
$socket = stream_socket_client("udp://127.0.0.1:" . $server->getPort());
var_dump(pong($socket));

$next = "MCPE;second;2193;1.0;3;10;1;w;Survival;1;19132;19133;";
$server->setAdvertisement($next);
$deadline = microtime(true) + 5;
do {
    $answer = pong($socket);
} while (($answer === null || $answer[1] !== $next) && microtime(true) < $deadline);
var_dump($answer[1]);
$server->stop(0);
?>
--EXPECT--
array(2) {
  [0]=>
  int(99)
  [1]=>
  string(52) "MCPE;first;2193;1.0;0;10;1;w;Survival;1;19132;19133;"
}
string(53) "MCPE;second;2193;1.0;3;10;1;w;Survival;1;19132;19133;"
