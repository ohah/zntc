function run(override) {
  for (let index = 0; index < 2; index++) {
    try {
      throw index;
    } catch (caught) {
      const captured = () => index + caught;
      return captured();
    } finally {
      if (override) return 'finally';
    }
  }
}
console.log(JSON.stringify([run(false), run(true)]));
