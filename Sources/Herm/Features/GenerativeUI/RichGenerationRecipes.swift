import Foundation

/// Acceptance recipes exercise reusable renderers; they are not another tool execution system.
enum RichGenerationRecipes {
    struct Recipe: Identifiable, Sendable {
        let id: String
        let prompt: String
        let feature: String
    }
    static let all: [Recipe] = [
        Recipe(
            id: "calculations",
            prompt: "Create a savings calculator with editable contributions and interest assumptions.", feature: "html"
        ),
        Recipe(
            id: "scheduling", prompt: "Organize these dated commitments into a selectable timeline.",
            feature: "timeline"),
        Recipe(
            id: "organization", prompt: "Turn these packing requirements into a checklist I can select and discuss.",
            feature: "checklist"),
        Recipe(
            id: "learning", prompt: "Create an offline quiz with answer explanations and a running score.",
            feature: "html"),
        Recipe(
            id: "decisions", prompt: "Compare these three options against cost, effort, and reliability.",
            feature: "comparison"),
        Recipe(
            id: "research", prompt: "Map these claims to their supplied supporting and contradicting evidence.",
            feature: "graph"),
        Recipe(
            id: "data", prompt: "Show these captured test results in a sortable table and a chart.",
            feature: "dataset.chart"),
        Recipe(
            id: "development",
            prompt: "Visualize these recorded state transitions; show only states included in the input.",
            feature: "graph"),
        Recipe(
            id: "ui-review",
            prompt: "Compare these two inline screenshots with an overlay slider and synchronized zoom.",
            feature: "imageComparison"),
        Recipe(
            id: "delivery",
            prompt:
                "Create a release checklist from these supplied checks; distinguish proposed work from observed results.",
            feature: "checklist"),
    ]
    static func fixture(for recipe: Recipe) -> String {
        if recipe.feature == "html" {
            let learning = recipe.id == "learning"
            let html = learning ? quiz : savings
            let document: [String: Any] = [
                "version": 1, "id": recipe.id, "title": learning ? "Practice quiz" : "Savings calculator",
                "fallback": learning
                    ? "An offline quiz with explanations." : "Explore monthly savings with supplied assumptions.",
                "kind": "html", "html": html,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
        guard let descriptor = RichFeatureRegistry.local.first(where: { $0.id == recipe.feature }) else { return "" }
        return RichFeatureRegistry.exampleSurface(descriptor)
    }

    private static let savings = """
        <main><h1>Savings calculator</h1><p>Illustrative projection: fixed monthly compounding, contributions at month end, no fees or taxes.</p>
        <label>Starting balance <input id="balance" type="number" min="0" value="1000"></label>
        <label>Monthly contribution <input id="monthly" type="number" min="0" value="200"></label>
        <label>Annual interest (%) <input id="rate" type="number" min="0" max="100" step="0.1" value="4"></label>
        <label>Years <input id="years" type="number" min="0" max="100" value="10"></label>
        <p>Projected balance: <output id="result" aria-live="polite"></output></p></main>
        <style>main{max-width:36rem;margin:auto;padding:1rem}label{display:flex;justify-content:space-between;gap:1rem;margin:1rem 0}input{width:7rem}p{line-height:1.5}</style>
        <script>const ids=['balance','monthly','rate','years'],inputs=ids.map(id=>document.getElementById(id));function update(){const [b,m,r,y]=inputs.map(el=>Math.max(0,Number(el.value)||0));const months=Math.min(1200,Math.round(y*12)),interest=Math.min(100,r)/1200;let total=b;for(let i=0;i<months;i++)total=total*(1+interest)+m;document.getElementById('result').textContent=total.toLocaleString(undefined,{maximumFractionDigits:2})}inputs.forEach(el=>el.addEventListener('input',update));update();</script>
        """

    private static let quiz = """
        <main><h1>Practice quiz</h1><p>Which structure processes entries in arrival order?</p><button id="queue">Queue</button> <button id="stack">Stack</button><p id="feedback" aria-live="polite"></p><p>Score: <output id="score">0 / 0</output></p><button id="reset">Try again</button></main>
        <style>main{max-width:36rem;margin:auto;padding:1rem}button{margin:.5rem 0;padding:.5rem}p{line-height:1.5}</style>
        <script>let answered=false;const queue=document.getElementById('queue'),stack=document.getElementById('stack');function answer(correct){if(answered)return;answered=true;document.getElementById('feedback').textContent='A queue uses first in, first out. A stack uses last in, first out.';document.getElementById('score').textContent=(correct?1:0)+' / 1';queue.disabled=stack.disabled=true}queue.onclick=()=>answer(true);stack.onclick=()=>answer(false);document.getElementById('reset').onclick=()=>{answered=false;queue.disabled=stack.disabled=false;document.getElementById('feedback').textContent='';document.getElementById('score').textContent='0 / 0'};</script>
        """
}
