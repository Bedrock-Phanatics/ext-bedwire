<?php
// Options every Server needs, plus a raw packet builder since the extension no longer encodes packets.
const VERSION = ["protocol_version" => 2225, "minecraft_version" => "1.26.60"];
const OPTIONS = VERSION + ["authentication" => false];

function packet(int $id, string $payload = ""): string {
    $header = "";
    do {
        $byte = $id & 0x7f;
        $id >>= 7;
        $header .= chr($id !== 0 ? $byte | 0x80 : $byte);
    } while ($id !== 0);
    return $header . $payload;
}

function packetId(string $bytes): int {
    $value = 0;
    for ($i = 0, $shift = 0; $i < 5; $i++, $shift += 7) {
        $byte = ord($bytes[$i]);
        $value |= ($byte & 0x7f) << $shift;
        if ($byte < 0x80) break;
    }
    return $value & 0x3ff;
}
