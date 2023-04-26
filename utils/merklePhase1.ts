import keccak256 from "keccak256";
import { MerkleTree } from "merkletreejs";
const ethers = require("ethers");
const fs = require("fs");

const whitelistFileName = "./whitelistPhase1.csv"
const whitelistedAddress = "0x005202D060f11AEd313155c47a7B67E564b711a9"

function getProofs(rawData) {  
  var result : any[] = [];
  
  for (const element of rawData) 
  {
    const address = element.split(",")[0].trim();
    const qty = element.split(",")[1].trim();
    const proof = ethers.utils.solidityKeccak256(['address', 'uint256'], [address, parseInt(qty)])    
    result.push(proof);
  }

  return result;
}

function getMerkleRoot()
{  
  const data = fs.readFileSync(whitelistFileName, "utf8");   
  const proofs = getProofs(data.toString().split("\n"));  
  
  let merkleTree = new MerkleTree(proofs, keccak256, { hashLeaves: false, sortPairs: true });
  let root = merkleTree.getHexRoot();     
  let proof = merkleTree.getHexProof(keccak256(whitelistedAddress));

  console.log("Root: ", root);
  console.log("Proof: ", proof);

  return root;      
}