const hre = require('hardhat')

async function main() {
  const [deployer] = await hre.ethers.getSigners()
  console.log('Deploying with:', deployer.address)

  const KITE_USDT = '0x0fF5393387ad2f9f691FD6Fd28e07E3969e27e63'

  const Presaga = await hre.ethers.getContractFactory('Presaga')
  const presaga = await Presaga.deploy(KITE_USDT)
  await presaga.waitForDeployment()

  const address = await presaga.getAddress()
  console.log('Presaga deployed to:', address)
  console.log('USDT:', KITE_USDT)
  console.log('\nAdd to your .env:')
  console.log(`PRESAGA_ADDRESS=${address}`)
}

main().catch(err => { console.error(err); process.exit(1) })
