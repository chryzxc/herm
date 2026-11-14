extension DockModel {
    func makeBotMode() -> BotModeModel {
        let bots = BotModeModel()
        bots.bind(to: controlRPCClient, capabilityAvailable: false)
        return bots
    }
}
