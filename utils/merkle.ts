import keccak256 from "keccak256";
import { MerkleTree } from "merkletreejs";

// Users in whitelist
const whiteListAddresses = [
  "0x8C652DB1A784A24a8Bad9Bfd5A9229fc64455e05",
  "0x30240B5E4246ab1087026Bfd91207e9E9c021D46",
];

const leaves = whiteListAddresses.map((x) => keccak256(x));
const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });

const root = "0x" + tree.getRoot().toString("hex");

// The root hash used to set merkle root in smart contract
console.log("Root Hash", root);

const hexProof = tree.getHexProof(
  keccak256("0x8C652DB1A784A24a8Bad9Bfd5A9229fc64455e05")
);

// Proof needed to prove that the address is in the white list
// Used in smart contract
console.log("Proof", hexProof);
