<?php

/**
 * @generate-class-entries
 * @undocumentable
 */

namespace Bedwire {

    class Exception extends \RuntimeException
    {
    }

    /** Thrown when a bounded queue is full; nothing was queued. */
    final class BackpressureException extends Exception
    {
    }

    /**
     * A RakNet listener with Bedrock sessions, run on a native network thread.
     * Single-use: once stopped, create a new Server to listen again.
     */
    final class Server
    {
        public const int EVENT_CONNECT = 1;
        public const int EVENT_DISCONNECT = 2;
        public const int EVENT_PACKET = 3;
        public const int EVENT_RECEIPT_ACK = 4;
        public const int EVENT_RECEIPT_FAILED = 5;
        public const int EVENT_PING = 6;
        public const int EVENT_RAW = 7;

        public const int REASON_REMOTE = 0;
        public const int REASON_SERVER = 1;
        public const int REASON_PROTOCOL = 2;
        public const int REASON_OVERLOAD = 3;
        public const int REASON_SHUTDOWN = 4;

        public function __construct(string $address, int $port, string $advertisement, array $options = []) {}

        public function stop(int $timeoutMs = 2000): void {}

        public function isRunning(): bool {}

        public function getPort(): int {}

        /**
         * Returns a flat list of [kind, session, data] triples.
         * Waits up to $timeoutMs only when no event is queued.
         */
        public function poll(int $maxEvents = 4096, int $timeoutMs = 0): array {}

        public function send(int $session, string $packet): bool {}

        public function sendBatch(int $session, array $packets): bool {}

        public function sendWithReceipt(int $session, array $packets): int|false {}

        public function disconnect(int $session): bool {}

        public function enableEncryption(int $session, string $handshakePacket, string $key): bool {}

        public function acceptLogin(int $session, string $clientPublicKey): bool {}

        public function setAdvertisement(string $advertisement): void {}

        public function blockAddress(string $address, int $seconds = 300): void {}

        public function unblockAddress(string $address): void {}

        public function sendRaw(string $address, int $port, string $payload): void {}

        public function getStatistics(): array {}
    }

    final class Nbt
    {
        public const int JAVA = 0;
        public const int BEDROCK = 1;
        public const int NETWORK = 2;

        private function __construct() {}

        public static function transcode(string $data, int $from, int $to, int $maxDepth = 512): string {}
    }
}
