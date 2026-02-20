# Add to the final summary section
if [[ " ${sec_choices[@]} " =~ " 1 " ]]; then
    echo "  • PentAGI: Edit ~/pentagi/.env with API keys, then docker-compose up -d"
fi
if [[ " ${sec_choices[@]} " =~ " 2 " ]]; then
    echo "  • PentestAgent: Edit ~/pentestagent/.env, then run 'pentestagent'"
fi
if [[ " ${sec_choices[@]} " =~ " 3 " ]]; then
    echo "  • HackerAI: Follow setup guide at https://github.com/hackerai-tech/hackerai"
fi
if [[ " ${sec_choices[@]} " =~ " 4 " ]]; then
    echo "  • HexStrike: Run 'hexstrike' to start server, configure AI clients"
fi
