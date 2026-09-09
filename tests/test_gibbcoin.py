"""Tests: ``python -m unittest discover -s tests`` (nur Standardbibliothek)."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from gibbcoin import crypto  # noqa: E402
from gibbcoin.block import merkle_root  # noqa: E402
from gibbcoin.chain import Blockchain, ValidationError, block_reward  # noqa: E402
from gibbcoin.miner import mine_block, mine_forever  # noqa: E402
from gibbcoin.params import COIN, HALVING_INTERVAL, INITIAL_REWARD, MIN_FEE  # noqa: E402
from gibbcoin.wallet import Wallet  # noqa: E402


class TestCrypto(unittest.TestCase):
    def test_sign_and_verify(self):
        seed = crypto.generate_seed()
        pub = crypto.public_key(seed)
        sig = crypto.sign(seed, b"gibbcoin")
        self.assertTrue(crypto.verify(pub, b"gibbcoin", sig))
        self.assertFalse(crypto.verify(pub, b"gibbcoin!", sig))

    def test_rfc8032_vector(self):
        seed = bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
        )
        self.assertEqual(
            crypto.public_key(seed).hex(),
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        )
        self.assertEqual(
            crypto.sign(seed, b"").hex(),
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        )

    def test_address_roundtrip(self):
        pub = crypto.public_key(crypto.generate_seed())
        address = crypto.public_key_to_address(pub)
        self.assertTrue(address.startswith("G"))
        self.assertTrue(crypto.is_valid_address(address))
        self.assertFalse(crypto.is_valid_address(address[:-1] + "x"))


class TestBlockchain(unittest.TestCase):
    def setUp(self):
        self.chain = Blockchain()
        self.alice = Wallet.create()
        self.bob = Wallet.create()

    def test_genesis(self):
        self.assertEqual(self.chain.height, 0)
        self.assertEqual(self.chain.supply, 0)

    def test_mining_pays_reward(self):
        mine_forever(self.chain, self.alice.address, blocks=1)
        self.assertEqual(self.chain.height, 1)
        self.assertEqual(self.chain.balance_of(self.alice.address), INITIAL_REWARD)

    def test_transfer(self):
        mine_forever(self.chain, self.alice.address, blocks=1)
        tx = self.alice.create_transaction(self.bob.address, 5 * COIN, nonce=0)
        self.assertTrue(self.chain.add_transaction(tx))
        mine_forever(self.chain, self.alice.address, blocks=1)

        self.assertEqual(self.chain.balance_of(self.bob.address), 5 * COIN)
        expected = 2 * INITIAL_REWARD - 5 * COIN
        self.assertEqual(self.chain.balance_of(self.alice.address), expected)

    def test_rejects_overspend(self):
        tx = self.alice.create_transaction(self.bob.address, 1 * COIN, nonce=0)
        with self.assertRaises(ValidationError):
            self.chain.add_transaction(tx)

    def test_rejects_tampered_signature(self):
        mine_forever(self.chain, self.alice.address, blocks=1)
        tx = self.alice.create_transaction(self.bob.address, 1 * COIN, nonce=0)
        tx.amount = 40 * COIN
        with self.assertRaises(ValidationError):
            self.chain.add_transaction(tx)

    def test_rejects_forged_proof_of_work(self):
        block = self.chain.candidate_block(self.alice.address)
        block.nonce = 1  # nicht gemint
        if block.meets_target():
            self.skipTest("Zufallstreffer ohne Mining")
        with self.assertRaises(ValidationError):
            self.chain.add_block(block)

    def test_rejects_inflated_coinbase(self):
        block = self.chain.candidate_block(self.alice.address)
        block.transactions[0].amount = INITIAL_REWARD * 10
        result = mine_block(block)
        with self.assertRaises(ValidationError):
            self.chain.add_block(result.block)

    def test_chain_links(self):
        mine_forever(self.chain, self.alice.address, blocks=3)
        for prev, block in zip(self.chain.blocks, self.chain.blocks[1:]):
            self.assertEqual(block.previous_hash, prev.hash())
            self.assertTrue(block.meets_target())

    def test_persistence(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "chain.json")
            chain = Blockchain(path)
            mine_forever(chain, self.alice.address, blocks=2)
            reloaded = Blockchain(path)
            self.assertEqual(reloaded.height, 2)
            self.assertEqual(reloaded.tip.hash(), chain.tip.hash())
            self.assertEqual(
                reloaded.balance_of(self.alice.address),
                chain.balance_of(self.alice.address),
            )

    def test_mempool_survives_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "chain.json")
            chain = Blockchain(path)
            mine_forever(chain, self.alice.address, blocks=1)
            tx = self.alice.create_transaction(self.bob.address, 2 * COIN, nonce=0)
            chain.add_transaction(tx)
            chain.save()

            reloaded = Blockchain(path)
            self.assertIn(tx.txid(), reloaded.mempool)
            mine_forever(reloaded, self.alice.address, blocks=1)
            self.assertEqual(reloaded.balance_of(self.bob.address), 2 * COIN)
            self.assertEqual(reloaded.mempool, {})

    def test_replace_chain_needs_more_work(self):
        mine_forever(self.chain, self.alice.address, blocks=2)
        other = Blockchain()
        mine_forever(other, self.bob.address, blocks=1)
        self.assertFalse(self.chain.replace_chain([b.to_dict() for b in other.blocks]))

        mine_forever(other, self.bob.address, blocks=3)
        self.assertTrue(self.chain.replace_chain([b.to_dict() for b in other.blocks]))
        self.assertEqual(self.chain.height, 4)
        self.assertEqual(self.chain.balance_of(self.alice.address), 0)

    def test_fee_goes_to_miner(self):
        mine_forever(self.chain, self.alice.address, blocks=1)
        fee = 5 * MIN_FEE
        tx = self.alice.create_transaction(self.bob.address, 1 * COIN, nonce=0, fee=fee)
        self.chain.add_transaction(tx)
        mine_forever(self.chain, self.bob.address, blocks=1)
        self.assertEqual(
            self.chain.balance_of(self.bob.address), INITIAL_REWARD + 1 * COIN + fee
        )


class TestMonetaryPolicy(unittest.TestCase):
    def test_halving(self):
        self.assertEqual(block_reward(1), INITIAL_REWARD)
        self.assertEqual(block_reward(HALVING_INTERVAL), INITIAL_REWARD // 2)
        self.assertEqual(block_reward(HALVING_INTERVAL * 2), INITIAL_REWARD // 4)
        self.assertEqual(block_reward(HALVING_INTERVAL * 64), 0)

    def test_total_supply_under_cap(self):
        total = sum(
            block_reward(h * HALVING_INTERVAL) * HALVING_INTERVAL for h in range(64)
        )
        self.assertLessEqual(total, 21_000_000 * COIN)


class TestMerkle(unittest.TestCase):
    def test_empty_and_single(self):
        self.assertEqual(merkle_root([]), "00" * 32)
        leaf = "ab" * 32
        self.assertEqual(merkle_root([leaf]), leaf)

    def test_order_matters(self):
        a, b = "11" * 32, "22" * 32
        self.assertNotEqual(merkle_root([a, b]), merkle_root([b, a]))


if __name__ == "__main__":
    unittest.main()
