// Pure signed-transaction decoder. Input arrives on stdin; never log raw bytes.
const fs = require('fs');
const { createRequire } = require('module');
const path = require('path');
const fromFrontend = createRequire(path.resolve(__dirname, '../../../deopt-v2-frontend/package.json'));
const { parseTransaction, serializeTransaction, recoverTransactionAddress, keccak256 } = fromFrontend('viem');

async function main() {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  if (Object.keys(input).length !== 1 || typeof input.raw !== 'string' ||
      !/^0x[0-9a-fA-F]+$/.test(input.raw) || input.raw.length > 20000) {
    throw new Error('invalid raw transaction input');
  }
  const raw = input.raw.toLowerCase();
  if (!raw.startsWith('0x02')) throw new Error('unsupported transaction type');
  const tx = parseTransaction(raw);
  if (tx.type !== 'eip1559' || !tx.to || (tx.accessList || []).length !== 0) {
    throw new Error('unsupported transaction shape or access list');
  }
  if (serializeTransaction(tx).toLowerCase() !== raw) throw new Error('noncanonical signed encoding');
  const from = await recoverTransactionAddress({ serializedTransaction: raw });
  const result = {
    type: tx.type, chainId: tx.chainId, nonce: tx.nonce,
    to: tx.to, valueWei: String(tx.value ?? 0n), data: tx.data || '0x',
    gasLimit: String(tx.gas), maxFeePerGas: String(tx.maxFeePerGas),
    maxPriorityFeePerGas: String(tx.maxPriorityFeePerGas),
    accessListLength: (tx.accessList || []).length, from,
    transactionHash: keccak256(raw), serializedLengthBytes: (raw.length - 2) / 2,
  };
  process.stdout.write(JSON.stringify(result));
}

main().catch(() => { process.stderr.write('signed transaction verification failed\n'); process.exit(1); });
