import fs from 'fs'

const filename = './scripts/contracts.json'

export const storeAddresses = (addresses: any) => {
  fs.writeFileSync(filename, JSON.stringify({ ...readCurrentAddresses(), ...addresses }))
}

const readCurrentAddresses = () => {
  try {
    return JSON.parse(fs.readFileSync(filename).toString())
  } catch (err) {
    return {}
  }
}
