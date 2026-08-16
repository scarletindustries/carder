try {
  try { throw 1 } catch (e) { console.log("inner"); throw 2 }
} catch (e) { console.log("outer", e) }
