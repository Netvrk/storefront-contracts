import keccak256 from "keccak256";
import { MerkleTree } from "merkletreejs";

// Users in whitelist
const whiteListAddresses = [
  "0x20eA1E1f04Bdd6B0f0E1Ec0BD6B1E17c0a186C7D",
  "0xB0d3C9aA49d41178FF6d856aA3f00da83A96F704",
];

const leaves = whiteListAddresses.map((x) => keccak256(x));
const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });

const root = "0x" + tree.getRoot().toString("hex");

// The root hash used to set merkle root in smart contract
console.log("Root Hash", root);

const hexProof = tree.getHexProof(
  keccak256("0x20eA1E1f04Bdd6B0f0E1Ec0BD6B1E17c0a186C7D")
);

// Proof needed to prove that the address is in the white list
// Used in smart contract
console.log("Proof", hexProof);
