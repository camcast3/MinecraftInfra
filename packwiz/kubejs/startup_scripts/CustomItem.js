ItemEvents.modification(event => {
  event.modify('botania:terra_sword', item => {
    item.attackSpeed = -2.8
  })
})

ItemEvents.modification(event => {
  event.modify('remnant_bosses:ossukage_sword', item => {
    item.attackSpeed = -2.5
  })
})