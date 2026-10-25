<?php

/**
 * @generate-class-entries
 * @undocumentable
 */

namespace Bedwire {
    class Exception extends \RuntimeException {}

    final class BackpressureException extends Exception {}

    final class PacketException extends Exception {}

    final class NbtException extends Exception {}

    /**
     * @strict-properties
     * @not-serializable
     */
    final class Server
    {
        public const int EVENT_CONNECT = 1;
        public const int EVENT_DISCONNECT = 2;
        public const int EVENT_PACKET = 3;
        public const int EVENT_LOGIN = 4;
        public const int EVENT_UNRELIABLE = 5;

        public const int REASON_REMOTE = 0;
        public const int REASON_SERVER = 1;
        public const int REASON_PROTOCOL = 2;
        public const int REASON_OVERLOAD = 3;
        public const int REASON_SHUTDOWN = 4;
        public const int REASON_AUTHENTICATION = 5;
        public const int REASON_TIMEOUT = 6;

        public function __construct(string $address, int $port, array $options = []) {}

        public function stop(int $timeoutMs = 2000): void {}

        public function isRunning(): bool {}

        public function getPort(): int {}

        public function setStatus(string $name, string $level, int $maxPlayers, int $gameType = 0): void {}

        public function poll(int $maxEvents = 4096, int $timeoutMs = 0): array {}

        public function send(int $session, string $packet): bool {}

        public function sendBatch(int $session, array $packets): bool {}

        public function sendPackets(int $session, array $packets): bool {}

        public function sendRawBatch(int $session, string $batch, int $offset = 0): bool {}

        public function sendUnreliable(int $session, string $payload): bool {}

        public function eventSignal(): int {}

        public static function waitForEvents(int $signal, int $seen, int $timeoutMs = 1000): ?int {}

        public function disconnect(int $session): bool {}

        public function acceptLogin(int $session, string $clientKeyDer): bool {}

        public function getStatistics(): array {}
    }

    /** @not-serializable */
    final class Protocol
    {
        public const int CLIENTBOUND = 1;
        public const int SERVERBOUND = 2;
        public const int BIDIRECTIONAL = 3;

        private function __construct() {}

        public static function id(string $name): int {}

        public static function name(int $id): ?string {}

        public static function direction(int|string $packet): int {}

        public static function header(string $bytes): array {}

        public static function packetId(string $bytes): int {}

        public static function decode(string $bytes, int $maxValues = 0): ?array {}

        public static function decodeMany(array $packets, int $maxValues = 0): array {}

        public static function encode(int|string $packet, array $fields, int $senderSubClient = 0, int $targetSubClient = 0): string {}

        public static function encodeMany(array $packets): array {}

        public static function encodeBatch(array $packets): string {}

        public static function schema(): array {}
    }

    /** @not-serializable */
    final class PacketId {}

    /** @not-serializable */
    final class Nbt
    {
        public const int JAVA = 0;
        public const int BEDROCK = 1;
        public const int NETWORK = 2;

        private function __construct() {}

        public static function transcode(string $data, int $from, int $to, int $maxDepth = 0): string {}

        public static function length(string $data, int $format, int $offset = 0, int $maxDepth = 0): int {}

        public static function read(string $data, int $format, int $offset = 0, int $maxDepth = 0): \pocketmine\nbt\TreeRoot {}

        public static function readAt(string $data, int $format, int $offset = 0, int $maxDepth = 0): array {}

        public static function readHeadless(string $data, int $format, int $type, int $offset = 0, int $maxDepth = 0): \pocketmine\nbt\tag\Tag {}

        public static function readHeadlessAt(string $data, int $format, int $type, int $offset = 0, int $maxDepth = 0): array {}

        public static function readMultiple(string $data, int $format, int $maxDepth = 0): array {}

        public static function write(\pocketmine\nbt\TreeRoot $root, int $format): string {}

        public static function writeHeadless(\pocketmine\nbt\tag\Tag $tag, int $format): string {}

        public static function writeMultiple(array $roots, int $format): string {}
    }
}
