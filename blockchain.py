"""Kompatibilitäts-Import für ältere Beispiele.

Diese Datei definiert absichtlich KEINE eigenen Klassen mehr. Die einzige
kanonische Implementierung lebt in `gibbcoin.py` im Projekt-Root. Ältere
Beispiele oder Skripte, die noch `from Code.blockchain import Blockchain`
verwenden, bekommen dieselben Klassen wie alle anderen Aufrufer.

Siehe test_gibbcoin.py::test_compatibility_import_uses_canonical_implementation
"""

from gibbcoin import Block, Blockchain, Transaction

__all__ = ["Block", "Blockchain", "Transaction"]
