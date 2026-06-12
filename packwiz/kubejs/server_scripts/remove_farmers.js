ServerEvents.recipes(event => {
	event.remove({ output: 'farmersrespite:coffee' })
	event.remove({ output: 'farmersrespite:long_coffee' })
	event.remove({ output: 'farmersrespite:strong_coffee' })
	event.remove({ output: 'farmersrespite:long_black_tea' })
	event.remove({ output: 'farmersrespite:strong_black_tea' })
})