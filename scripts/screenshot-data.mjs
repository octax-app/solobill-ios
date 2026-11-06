// Adds fictional customers, subscriptions and six months of invoices for screenshots.
// Run it after scripts/dev-server.sh is up: node scripts/screenshot-data.mjs [url]
const url = `${process.argv[2] ?? 'http://localhost:3100'}/api/v1`
if (!/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/api\/v1$/.test(url)) {
  throw new Error('Screenshot data only goes to a server on localhost')
}

let token = ''
async function call(method, route, data) {
  const response = await fetch(url + route, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: data === undefined ? undefined : JSON.stringify(data),
  })
  const json = await response.json()
  if (!response.ok) throw new Error(`${method} ${route}: ${JSON.stringify(json)}`)
  return json
}
const signedIn = await call('POST', '/auth/token', {
  email: 'owner@example.com',
  password: 'demo-password',
  name: 'Screenshot data',
})
token = signedIn.token

const FX = { USD: 100_000_000, OMR: 260_000_000, AED: 27_225_000, EUR: 108_000_000, SAR: 26_660_000 }
const day = (date) => date.toISOString().slice(0, 10)
const monthStart = (back) => {
  const now = new Date()
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - back, 1))
}
const services = await call('GET', '/services')
const service = (name) => services.find((row) => row.name === name)

const people = [
  ['Sara Lindqvist', 'Northwind Studio', 'EUR'],
  ['Khalid Al Mansoori', 'Desert Bloom Florists', 'AED'],
  ['Priya Raman', 'Lumen Analytics', 'USD'],
  ['Yousef Al Harthy', 'Harthy Engineering', 'OMR'],
  ['Mei Tanaka', 'Paper Crane Books', 'USD'],
  ['Faisal Al Qahtani', 'Qahtani Trading', 'SAR'],
  ['Elena Rossi', 'Rossi Architetti', 'EUR'],
]
const customers = []
for (const [name, company, currency] of people) {
  const email = `${name.split(' ')[0].toLowerCase()}@example.com`
  customers.push(await call('POST', '/customers', { name, company, email, currency }))
}

const catalog = [
  ['Dedicated server', 'Dedicated server', 600_000, 950_000],
  ['QuickBooks Online', 'QuickBooks Online', 300_000, 420_000],
  ['S3 storage (R2)', 'Object storage', 150_000, 290_000],
  ['Domain', 'Domain renewal', 120_000, 250_000],
  ['Apple developer account', 'Apple developer account', 990_000, 1_350_000],
]

for (const [i, customer] of customers.entries()) {
  const [name, description, costAmount, priceAmount] = catalog[i % catalog.length]
  const found = service(name)
  if (!found) continue
  const started = monthStart(6 - (i % 6))
  started.setUTCDate(10 + i)
  await call('POST', '/subscriptions', {
    customerId: customer.id,
    serviceId: found.id,
    startedOn: day(started),
    lines: [{ description, costAmount, priceAmount }],
    costCurrency: 'USD',
    priceCurrency: 'USD',
  })
}

let count = 0
for (let back = 5; back >= 0; back--) {
  const perMonth = 2 + (back % 3)
  for (let k = 0; k < perMonth; k++) {
    const customer = customers[count % customers.length]
    const [, description, cost, price] = catalog[count % catalog.length]
    const scale = 1 + ((count * 7) % 5) / 4
    const issued = monthStart(back)
    issued.setUTCDate(back === 0 ? 1 + k : 3 + ((count * 5) % 20))
    const due = new Date(issued)
    due.setUTCDate(28)
    const currency = customer.currency
    const month = issued.toLocaleString('en', { month: 'long', timeZone: 'UTC' })
    const draft = await call('POST', '/invoices', {
      type: 'invoice',
      customerId: customer.id,
      currency,
      fxRate: FX[currency],
      taxEnabled: currency !== 'USD',
      taxRate: 50_000,
      issueDate: day(issued),
      dueOn: day(due),
      lines: [
        {
          description: `${description}, ${month}`,
          quantity: 10_000,
          unitPrice: Math.round((price * scale * FX.USD) / FX[currency] / 10) * 10,
          costAmount: Math.round(cost * scale),
          costCurrency: 'USD',
          costFxRate: FX.USD,
        },
      ],
    })
    const invoice = await call('POST', `/invoices/${draft.id}/issue`)
    if (back > 1 || (back === 1 && k === 0)) {
      const paid = new Date(issued)
      paid.setUTCDate(25)
      await call('POST', `/invoices/${invoice.id}/paid`, { paidOn: day(paid) })
    }
    count++
  }
}
console.log(`Added ${customers.length} customers and ${count} invoices`)
