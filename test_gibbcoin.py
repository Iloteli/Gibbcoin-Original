import unittest

from Code.blockchain import Blockchain as CompatibilityBlockchain
from gibbcoin import Blockchain


class BlockchainTests(unittest.TestCase):
    def test_compatibility_import_uses_canonical_implementation(self):
        self.assertIs(CompatibilityBlockchain, Blockchain)

    def test_new_chain_is_valid(self):
        self.assertTrue(Blockchain(difficulty=1).is_valid())

    def test_mining_links_blocks_and_clears_pending_transactions(self):
        blockchain = Blockchain(difficulty=1)
        blockchain.add_transaction("Alice", "Bob", 10)

        block = blockchain.mine_block("Miner1")

        self.assertEqual(block.index, 1)
        # 1 ausstehende Transaktion + 1 automatische Mining-Belohnung
        self.assertEqual(len(block.transactions), 2)
        self.assertEqual(block.previous_hash, blockchain.chain[0].hash)
        self.assertEqual(blockchain.pending_transactions, [])
        self.assertTrue(blockchain.is_valid())

    def test_mining_grants_reward_to_miner(self):
        blockchain = Blockchain(difficulty=1, mining_reward=50)
        block = blockchain.mine_block("Miner1")

        reward_txs = [tx for tx in block.transactions if tx.sender == "NETWORK"]
        self.assertEqual(len(reward_txs), 1)
        self.assertEqual(reward_txs[0].recipient, "Miner1")
        self.assertEqual(reward_txs[0].amount, 50)
        self.assertEqual(blockchain.get_balance("Miner1"), 50)

    def test_tampering_is_detected(self):
        blockchain = Blockchain(difficulty=1)
        blockchain.add_transaction("Alice", "Bob", 10)
        blockchain.mine_block("Miner1")
        original = blockchain.chain[1]
        blockchain.chain[1] = original.__class__(
            index=original.index,
            timestamp=original.timestamp,
            transactions=original.transactions,
            miner=original.miner,
            previous_hash=original.previous_hash,
            nonce=original.nonce,
            hash="tampered",
        )

        self.assertFalse(blockchain.is_valid())

    def test_invalid_transactions_are_rejected(self):
        blockchain = Blockchain(difficulty=1)
        for amount in (0, -1):
            with self.subTest(amount=amount):
                with self.assertRaises(ValueError):
                    blockchain.add_transaction("Alice", "Bob", amount)
        with self.assertRaises(ValueError):
            blockchain.add_transaction("Alice", "Alice", 1)

    def test_get_balance_tracks_sends_and_receives(self):
        blockchain = Blockchain(difficulty=1)
        blockchain.add_transaction("Alice", "Bob", 30)
        blockchain.mine_block("Miner1")

        self.assertEqual(blockchain.get_balance("Bob"), 30)
        self.assertEqual(blockchain.get_balance("Alice"), -30)

    def test_save_and_load_round_trip(self, tmp_path=None):
        import tempfile
        from pathlib import Path

        blockchain = Blockchain(difficulty=1)
        blockchain.add_transaction("Alice", "Bob", 10)
        blockchain.mine_block("Miner1")

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "chain.json"
            blockchain.save(path)
            loaded = Blockchain.load(path)

        self.assertTrue(loaded.is_valid())
        self.assertEqual(loaded.get_balance("Bob"), 10)
        self.assertEqual(len(loaded.chain), len(blockchain.chain))


if __name__ == "__main__":
    unittest.main()
